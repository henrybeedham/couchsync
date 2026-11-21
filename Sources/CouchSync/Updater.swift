import AppKit
import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer CouchSync, downloads it, and swaps it in.
///
/// The new app is installed when CouchSync quits (or straight away with
/// "Restart"), never in the middle of a film. Since the last party is resumed
/// on launch, restarting to update puts you back in the party.
@MainActor
final class Updater: ObservableObject {
    static let repo = "henrybeedham/couchsync"
    static let checkInterval: TimeInterval = 6 * 60 * 60

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let asset: URL
        let sha256: String?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, ready, installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Release?
    @Published private(set) var lastChecked: Date?
    @Published var showPanel = false
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "autoUpdate")
            if automatic, phase == .available { download() }
        }
    }

    let current: String
    /// Why this copy can't replace itself, if it can't.
    let cannotInstall: String?
    /// Shows a short message in the window.
    var notify: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private let bundleURL = Bundle.main.bundleURL
    private var staged: URL?
    private var timer: Timer?

    init() {
        current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        automatic = defaults.object(forKey: "autoUpdate") as? Bool ?? true
        lastChecked = defaults.object(forKey: "lastUpdateCheck") as? Date

        let path = bundleURL.path
        if bundleURL.pathExtension != "app" {
            cannotInstall = "Updates only work in the built app."
        } else if path.contains("/AppTranslocation/") {
            cannotInstall = "Move CouchSync to your Applications folder to update it."
        } else if !FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            cannotInstall = "CouchSync can't write to the folder it's in."
        } else {
            cannotInstall = nil
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installOnQuit() }
        }
    }

    /// Checks shortly after launch and then every few hours.
    func start() {
        guard timer == nil, bundleURL.pathExtension == "app", Debug.updates else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    var isBusy: Bool { [.checking, .downloading, .installing].contains(phase) }
    var hasUpdate: Bool { phase == .available || phase == .ready || phase == .downloading }

    // MARK: Checking

    func check(userInitiated: Bool = false) {
        if userInitiated { showPanel = true }
        guard !isBusy, phase != .ready else { return }
        phase = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                lastChecked = Date()
                defaults.set(lastChecked, forKey: "lastUpdateCheck")
                if let release, Self.isNewer(release.version, than: current) {
                    log("update: \(release.version) available (have \(current))")
                    latest = release
                    phase = .available
                    if automatic && cannotInstall == nil { download() }
                } else {
                    latest = nil
                    phase = .upToDate
                }
            } catch {
                log("update: check failed: \(error.localizedDescription)")
                phase = userInitiated ? .failed("Couldn't check for updates. \(error.localizedDescription)") : .idle
            }
        }
    }

    private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CouchSync", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }  // no releases yet
        guard status == 200 else { throw UpdateError("GitHub answered \(status).") }
        return parse(data)
    }

    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }

        let zip = assets.first { ($0["name"] as? String).map { $0.hasPrefix("CouchSync") && $0.hasSuffix(".zip") } ?? false }
        guard let zip, let link = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https", link.host == "github.com",
              link.path.hasPrefix("/\(repo)/releases/download/") else { return nil }

        let digest = (zip["digest"] as? String).flatMap { d in
            d.hasPrefix("sha256:") ? String(d.dropFirst(7)).lowercased() : nil
        }
        var version = tag
        if version.hasPrefix("v") { version.removeFirst() }
        return Release(version: version, notes: whatsNew(json["body"] as? String ?? ""),
                       page: page, asset: link, sha256: digest)
    }

    /// The release notes up to the install steps, without the heading.
    private static func whatsNew(_ body: String) -> String {
        var lines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### Install") || trimmed.hasPrefix("**Full Changelog**") { break }
            if trimmed.hasPrefix("#") && trimmed.lowercased().contains("what's new") { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Downloading

    func download() {
        guard let release = latest, cannotInstall == nil, phase == .available || isFailed else { return }
        phase = .downloading
        let bundleURL = bundleURL
        Task {
            do {
                let app = try await Self.fetchAndVerify(release, near: bundleURL)
                staged = app
                phase = .ready
                log("update: \(release.version) ready at \(app.path)")
                if !showPanel {
                    notify?("CouchSync \(release.version) will install when you quit.")
                }
            } catch {
                log("update: download failed: \(error.localizedDescription)")
                phase = .failed("The update didn't download. \(error.localizedDescription)")
            }
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private nonisolated static func fetchAndVerify(_ release: Release, near bundleURL: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: release.asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        defer { try? FileManager.default.removeItem(at: file) }

        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError("The download was damaged.") }
        }

        // Unpack next to the app, on the same disk, so the swap is a rename.
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: bundleURL, create: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path])
        let app = staging.appendingPathComponent("CouchSync.app")

        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The download isn't the expected app.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    // MARK: Installing

    /// Quits, swaps in the new app and opens it.
    func restartToUpdate() {
        guard phase == .ready, spawnInstaller(relaunch: true) else { return }
        phase = .installing
        // macOS won't quit while a sheet is open, so close it first.
        showPanel = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private func installOnQuit() {
        guard phase == .ready else { return }
        _ = spawnInstaller(relaunch: false)
        phase = .installing
    }

    /// A small script that waits for this process to exit, then replaces the
    /// app. If the swap fails it puts the old app back.
    private func spawnInstaller(relaunch: Bool) -> Bool {
        guard let staged, FileManager.default.fileExists(atPath: staged.path) else {
            phase = .failed("The downloaded update is gone. Check again.")
            return false
        }
        let script = """
        pid="$1"; new="$2"; dest="$3"; relaunch="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        old="$dest.previous"
        rm -rf "$old"
        mv "$dest" "$old" || exit 1
        if mv "$new" "$dest"; then rm -rf "$old"; else mv "$old" "$dest"; fi
        rm -rf "$(dirname "$new")"
        [ "$relaunch" = 1 ] && open "$dest"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(getpid()), staged.path, bundleURL.path,
                             relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            log("update: installer started (relaunch: \(relaunch))")
            return true
        } catch {
            phase = .failed("Couldn't start the installer.")
            return false
        }
    }

    // MARK: Helpers

    private nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(tool.hasSuffix("codesign") ? "The new app's signature is invalid." : "Couldn't unpack the update.")
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
