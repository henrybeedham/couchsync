import AppKit
import WebKit

/// Owns the web view and translates between the injected script and the party.
final class WebController: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    static let home = URL(string: "https://www.netflix.com/browse")!

    let webView: WKWebView
    weak var session: PartySession?

    @Published private(set) var title = "CouchSync"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isFullscreen = false

    /// The title the page's script is attached to, if any.
    private var attachedVideoId: String?
    /// A title the party sent us to. Until it loads, the outgoing page's events are ignored.
    private var pendingNavigation: (videoId: String, until: Date)?
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        // Makes the user agent identical to Safari's, which Netflix expects.
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        // Lets a remote "play" start playback without a local click.
        config.mediaTypesRequiringUserActionForPlayback = []
        // The page's fullscreen requests are handled by SyncScript instead.
        config.preferences.isElementFullscreenEnabled = false
        // Keeps WebKit out of the keychain (and its password prompts).
        WebCryptoKey.install(on: config.websiteDataStore)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        installScripts()
        watchWindows()

        config.userContentController.add(self, name: "couchsync")
        webView.uiDelegate = self
        webView.navigationDelegate = self  // supplies the WebCrypto key
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true

        observers = [
            webView.observe(\.title) { [weak self] view, _ in
                let title = view.title ?? ""
                self?.title = title.isEmpty ? "CouchSync" : title
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in self?.canGoBack = view.canGoBack },
            webView.observe(\.canGoForward) { [weak self] view, _ in self?.canGoForward = view.canGoForward },
        ]
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func installScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: "window.__couchsyncFullscreen = \(isFullscreen);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: SyncScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: Fullscreen

    /// Tracks whichever window the web view is in, including when AppKit moves it
    /// around during a fullscreen transition.
    private func watchWindows() {
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didBecomeKeyNotification] {
            center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === webView.window else { return }
        log("window \(note.name.rawValue) fullscreen=\(window.styleMask.contains(.fullScreen))")
        setFullscreen(window.styleMask.contains(.fullScreen), force: note.name != NSWindow.didBecomeKeyNotification)
    }

    /// `force` re-tells the page even if nothing changed here, e.g. after a
    /// transition the page started that ended up not happening.
    private func setFullscreen(_ on: Bool, force: Bool = false) {
        guard isFullscreen != on || force else { return }
        if isFullscreen != on {
            isFullscreen = on
            installScripts()
        }
        call("setFullscreen", on ? "true" : "false")
    }

    /// The page asked to enter or leave fullscreen.
    private func pageWantsFullscreen(_ on: Bool) {
        guard let window = webView.window else { return }
        log("page wants fullscreen=\(on), window is \(window.styleMask.contains(.fullScreen))")
        if window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
            // If the window didn't follow (say, a transition was already
            // underway), put the page back in line with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak window] in
                guard let self, let window, window === self.webView.window else { return }
                let actual = window.styleMask.contains(.fullScreen)
                if actual != on { self.setFullscreen(actual, force: true) }
            }
        }
    }

    func toggleFullscreen() {
        webView.window?.toggleFullScreen(nil)
    }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goHome() { load(Self.home) }

    // MARK: Party -> page

    func apply(_ state: SharedState, force: Bool) {
        if attachedVideoId == state.videoId {
            call("apply", Self.payload(state), force ? "true" : "false")
        } else if force {
            navigate(toVideo: state.videoId)
        }
    }

    func announce() {
        call("announce")
    }

    /// Only ever navigates to a Netflix watch page; a peer can't send us anywhere else.
    private func navigate(toVideo videoId: String) {
        guard !videoId.isEmpty, videoId.count <= 20, videoId.allSatisfy(\.isNumber),
              let url = URL(string: "https://www.netflix.com/watch/\(videoId)") else { return }
        if let pending = pendingNavigation, pending.videoId == videoId, pending.until > Date() { return }
        pendingNavigation = (videoId, Date().addingTimeInterval(15))
        log("navigating to \(videoId)")
        webView.load(URLRequest(url: url))
    }

    private func call(_ function: String, _ arguments: String...) {
        let js = "window.__couchsync && window.__couchsync.\(function)(\(arguments.joined(separator: ",")))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func payload(_ state: SharedState) -> String {
        let object: [String: Any] = ["paused": state.paused, "pos": state.currentPos]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return json
    }

    // MARK: Page -> party

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let videoId = body["videoId"] as? String

        switch type {
        case "ready":
            guard let videoId else { return }
            attachedVideoId = videoId
            if pendingNavigation?.videoId == videoId { pendingNavigation = nil }
            log("video ready \(videoId)")
            if let state = session?.videoReady(videoId) {
                call("init", Self.payload(state))
            } else {
                call("init", "null")
            }

        case "gone":
            attachedVideoId = nil
            session?.videoGone()

        case "state", "tick":
            guard let videoId,
                  let paused = body["paused"] as? Bool,
                  let pos = (body["pos"] as? NSNumber)?.doubleValue, pos.isFinite else { return }
            if let pending = pendingNavigation, pending.until > Date(), pending.videoId != videoId { return }
            if type == "state" {
                session?.localState(videoId: videoId, paused: paused, pos: pos,
                                    reason: body["reason"] as? String ?? "")
            } else {
                session?.localTick(videoId: videoId, paused: paused, pos: pos)
            }

        case "fullscreen":
            if let on = body["on"] as? Bool { pageWantsFullscreen(on) }

        case "warn":
            if let text = body["message"] as? String { session?.warn(text) }

        default:
            break
        }
    }

    // MARK: WKUIDelegate

    /// Links that want a new window open in this one instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
