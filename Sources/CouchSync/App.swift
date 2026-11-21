import SwiftUI
import WebKit

/// Environment overrides, used for testing without the UI.
///   COUCHSYNC_URL      page to open instead of Netflix
///   COUCHSYNC_AUTO     "host" or "join:<address>"
///   COUCHSYNC_NAME     display name
///   COUCHSYNC_PORT     party port
///   COUCHSYNC_VERBOSE  log sync activity to stderr
///   COUCHSYNC_DEFAULTS defaults suite for remembered parties
///   COUCHSYNC_NO_UPDATES don't check for updates on launch
enum Debug {
    private static let env = ProcessInfo.processInfo.environment
    static let verbose = env["COUCHSYNC_VERBOSE"] != nil
    static let name = env["COUCHSYNC_NAME"]
    static let auto = env["COUCHSYNC_AUTO"]
    static let port = env["COUCHSYNC_PORT"].flatMap { UInt16($0) }
    static let url: URL? = env["COUCHSYNC_URL"].flatMap { URL(string: $0) }
    static let updates = env["COUCHSYNC_NO_UPDATES"] == nil
    /// COUCHSYNC_DEFAULTS: a separate defaults suite for remembered parties, so test runs
    /// don't touch the real ones.
    static let defaults = env["COUCHSYNC_DEFAULTS"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
}

final class AppModel: ObservableObject {
    let session = PartySession(port: Debug.port ?? PartySession.defaultPort)
    let web = WebController()
    let chat = ChatModel()

    @Published var showParty = false

    init() {
        session.web = web
        session.chat = chat
        web.session = session
        chat.session = session
        web.load(Debug.url ?? WebController.home)

        if let auto = Debug.auto {
            if auto == "host" {
                session.host()
            } else if auto.hasPrefix("join:") {
                session.join(String(auto.dropFirst(5)))
            }
        } else {
            session.resume()
        }
    }

    func toggleChat() {
        withAnimation(.easeInOut(duration: 0.2)) { chat.isVisible.toggle() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CouchSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("CouchSync", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.session)
                .environmentObject(model.web)
                .environmentObject(model.chat)
                .environmentObject(updater)
                .frame(minWidth: 720, minHeight: 460)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $updater.showPanel) {
                    UpdatePanel()
                        .environmentObject(updater)
                        .environmentObject(model.session)
                }
                .onAppear {
                    let session = model.session
                    updater.notify = { session.warn($0) }
                    updater.start()
                }
        }
        .defaultSize(width: 1400, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check(userInitiated: true) }
            }
            CommandGroup(after: .toolbar) {
                Button("Show or Hide Chat") { model.toggleChat() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Reload Page") { model.web.webView.reload() }
                    .keyboardShortcut("r")
                Button("Netflix Home") { model.web.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(updater)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var session: PartySession
    @EnvironmentObject private var web: WebController
    @EnvironmentObject private var chat: ChatModel

    var body: some View {
        HStack(spacing: 0) {
            WebViewHost(webView: web.webView)
                .overlay { FloatingReactionsView() }
                .overlay(alignment: .bottomLeading) { toast }

            if chat.isVisible {
                Divider()
                ChatPanel()
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea(edges: web.isFullscreen ? .all : .bottom)
        .modifier(ToolbarHidesInFullscreen())
        .navigationTitle(web.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { web.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!web.canGoBack)
                    .help("Back")
                Button { web.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!web.canGoForward)
                    .help("Forward")
                Button { web.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                UpdateButton()

                Button { app.showParty.toggle() } label: {
                    Label(partyLabel, systemImage: partyIcon)
                        .labelStyle(.titleAndIcon)
                }
                .help("Party")
                .popover(isPresented: $app.showParty, arrowEdge: .bottom) {
                    PartyPanel().environmentObject(session)
                }

                Button { app.toggleChat() } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .overlay(alignment: .topTrailing) {
                            if chat.unread > 0 && !chat.isVisible {
                                Text(chat.unread > 9 ? "9+" : "\(chat.unread)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.red, in: Capsule())
                                    .offset(x: 9, y: -7)
                            }
                        }
                }
                .help(chat.isVisible ? "Hide chat (⇧⌘C)" : "Show chat (⇧⌘C)")
            }
        }
    }

    private var partyLabel: String {
        let others = session.members.count
        switch session.mode {
        case .idle: return "Party"
        case .connecting: return "Connecting…"
        case .hosting: return others == 0 ? "Hosting" : "Hosting · \(others + 1)"
        case .joined: return "In party · \(others + 1)"
        }
    }

    private var partyIcon: String {
        switch session.mode {
        case .idle: return "person.2"
        case .connecting: return "ellipsis"
        case .hosting: return "dot.radiowaves.left.and.right"
        case .joined: return "person.2.fill"
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = session.toast {
            Text(toast.text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassCapsule()
                .padding(18)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(3.5))
                    if session.toast?.id == toast.id {
                        withAnimation { session.toast = nil }
                    }
                }
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// In fullscreen the toolbar slides in only when the mouse reaches the top,
/// so the video gets the whole screen.
private struct ToolbarHidesInFullscreen: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later, frosted material before that.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
    }
}
