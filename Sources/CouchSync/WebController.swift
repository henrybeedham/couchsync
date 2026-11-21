import AppKit
import WebKit

/// Owns the web view and translates between the injected script and the party.
final class WebController: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    weak var session: PartySession?

    @Published private(set) var title = "CouchSync"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isFullscreen = false
    /// The service the page is on, or was last on.
    @Published private(set) var service: StreamingService = WebController.lastService

    /// The title the page's script is attached to, if any.
    private var attachedVideoId: String?
    /// The frame whose video is being synced: the page, or a player frame in it.
    private var videoFrame: (token: String, info: WKFrameInfo)?
    /// A title the party sent us to. Until it loads, the outgoing page's events are ignored.
    private var pendingNavigation: (videoId: String, until: Date)?
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        // Makes the user agent identical to Safari's, which the services expect.
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
            webView.observe(\.url) { [weak self] _, _ in
                DispatchQueue.main.async { self?.urlChanged() }
            },
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
            source: SyncScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        if let frame = videoFrame, !frame.info.isMainFrame {
            // The player is in a frame: the page grows the frame to fill the
            // window, and the frame's player is told it's fullscreen.
            call("frameFullscreen", on ? "true" : "false", in: nil)
            call("setFullscreen", on ? "true" : "false", in: frame.info)
        } else {
            call("setFullscreen", on ? "true" : "false", in: nil)
        }
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

    func goHome() { load(service.home) }

    func open(_ service: StreamingService) {
        self.service = service
        UserDefaults.standard.set(service.id, forKey: "service")
        load(service.home)
    }

    static var lastService: StreamingService {
        UserDefaults.standard.string(forKey: "service").flatMap(Services.service(id:)) ?? Services.netflix
    }

    /// The party's ID for what the page is showing. Test pages (COUCHSYNC_URL)
    /// that aren't on a service are their own title.
    private var currentVideoId: String? {
        if let id = Services.videoId(for: webView.url) { return id }
        guard Debug.url != nil, let url = webView.url, Services.service(for: url) == nil else { return nil }
        return "page:\(url.host ?? "")\(url.path)"
    }

    /// Single-page sites (YouTube, for one) change title without loading a
    /// new page, so the script is asked to start over with the new one.
    private func urlChanged() {
        if let now = Services.service(for: webView.url), now != service {
            service = now
            UserDefaults.standard.set(now.id, forKey: "service")
        }
        guard let frame = videoFrame, currentVideoId != attachedVideoId else { return }
        log("page moved to \(currentVideoId ?? "no title")")
        call("reset", in: frame.info)
    }

    // MARK: Party -> page

    func apply(_ state: SharedState, force: Bool) {
        if attachedVideoId == state.videoId {
            call("apply", Self.payload(state), force ? "true" : "false", in: videoFrame?.info)
        } else if force {
            navigate(toVideo: state.videoId)
        }
    }

    func announce() {
        call("announce", in: videoFrame?.info)
    }

    /// Only ever navigates to a watch page CouchSync builds itself from a
    /// checked title ID (see Services); a peer can't send us anywhere else.
    private func navigate(toVideo videoId: String) {
        guard let url = Services.watchURL(for: videoId) else { return }
        if let pending = pendingNavigation, pending.videoId == videoId, pending.until > Date() { return }
        pendingNavigation = (videoId, Date().addingTimeInterval(15))
        log("navigating to \(videoId)")
        webView.load(URLRequest(url: url))
        // Some services open a title's page without starting it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            // Still waiting: the video never appeared.
            guard let self, self.attachedVideoId != videoId,
                  self.pendingNavigation?.videoId == videoId else { return }
            let name = Services.parse(videoId)?.0.name ?? "the service"
            self.session?.warn("Press play to join the party on \(name).")
        }
    }

    /// Calls the script in `frame` (nil: the page itself).
    private func call(_ function: String, _ arguments: String..., in frame: WKFrameInfo?) {
        let js = "window.__couchsync && window.__couchsync.\(function)(\(arguments.joined(separator: ",")))"
        webView.evaluateJavaScript(js, in: frame, in: .page, completionHandler: { _ in })
    }

    private static func payload(_ state: SharedState) -> String {
        let object: [String: Any] = ["paused": state.paused, "pos": state.currentPos]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return json
    }

    // MARK: Page -> party

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let token = body["token"] as? String else { return }
        // A frame counts only if it's the page itself, or a player frame
        // belonging to the service the page is on.
        if !frame.isMainFrame {
            guard let page = Services.service(for: webView.url),
                  page.owns(host: frame.securityOrigin.host) else { return }
        }
        let fromVideoFrame = videoFrame?.token == token
        if fromVideoFrame { videoFrame = (token, frame) }

        switch type {
        case "ready":
            // Ignore thumbnails and previews when the video is elsewhere.
            let area = (body["area"] as? NSNumber)?.doubleValue ?? 0
            if !frame.isMainFrame && area < 40_000 { return }
            videoFrame = (token, frame)
            guard let videoId = currentVideoId else {
                attachedVideoId = nil
                log("video on a page with no title (\(webView.url?.absoluteString ?? ""))")
                return
            }
            attachedVideoId = videoId
            if pendingNavigation?.videoId == videoId { pendingNavigation = nil }
            log("video ready \(videoId)\(frame.isMainFrame ? "" : " in frame \(frame.securityOrigin.host)")")
            if let state = session?.videoReady(videoId) {
                call("init", Self.payload(state), in: frame)
            } else {
                call("init", "null", in: frame)
            }
            if isFullscreen { setFullscreen(true, force: true) }

        case "gone":
            guard fromVideoFrame else { return }
            videoFrame = nil
            attachedVideoId = nil
            session?.videoGone()

        case "state", "tick":
            guard fromVideoFrame, let videoId = attachedVideoId,
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
