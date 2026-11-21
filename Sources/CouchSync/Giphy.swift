import AppKit
import SwiftUI

/// Search and trending GIFs from GIPHY. Needs a free API key from developers.giphy.com,
/// either baked in at build time (Info.plist `GiphyAPIKey`) or pasted into the app.
enum Giphy {
    struct Result: Identifiable, Equatable {
        let id: String
        let title: String
        /// Small, light version for the picker grid.
        let preview: URL
        /// What gets sent to the chat.
        let gif: ChatMessage.Gif
    }

    enum Failure: LocalizedError {
        case badKey
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badKey: return "GIPHY didn't accept that API key."
            case .http(let code): return "GIPHY returned an error (\(code))."
            }
        }
    }

    static var bundledKey: String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "GiphyAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static var apiKey: String? {
        let saved = UserDefaults.standard.string(forKey: "giphyKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty { return saved }
        return bundledKey
    }

    /// Peers can only make us load images from GIPHY's media servers.
    static func isAllowedMedia(_ string: String) -> Bool {
        guard string.count <= 500, let url = URL(string: string), url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "giphy.com" || host.hasSuffix(".giphy.com")
    }

    static func fetch(query: String, key: String) async throws -> [Result] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/" + (q.isEmpty ? "trending" : "search"))!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "rating", value: "pg-13"),
        ] + (q.isEmpty ? [] : [URLQueryItem(name: "q", value: String(q.prefix(50)))])

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.badKey }
        guard status == 200 else { throw Failure.http(status) }
        return parse(data)
    }

    static func parse(_ data: Data) -> [Result] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }

        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let images = item["images"] as? [String: Any],
                  let full = images["fixed_width"] as? [String: Any],
                  let url = full["url"] as? String, isAllowedMedia(url),
                  let width = number(full["width"]), let height = number(full["height"]), width > 0, height > 0
            else { return nil }
            let small = (images["fixed_width_downsampled"] as? [String: Any])?["url"] as? String
            let previewString = small.flatMap { isAllowedMedia($0) ? $0 : nil } ?? url
            guard let preview = URL(string: previewString) else { return nil }
            let title = item["title"] as? String ?? ""
            return Result(id: id, title: title, preview: preview,
                          gif: ChatMessage.Gif(url: url, width: width, height: height, title: title))
        }
    }
}

@MainActor
final class GifSearch: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { schedule(delay: 0.35) } }
    }
    @Published private(set) var results: [Giphy.Result] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var key: String? = Giphy.apiKey

    private var task: Task<Void, Never>?

    func start() {
        if results.isEmpty { schedule(delay: 0) }
    }

    func save(key newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: "giphyKey")
        key = trimmed
        schedule(delay: 0)
    }

    func forgetKey() {
        UserDefaults.standard.removeObject(forKey: "giphyKey")
        key = Giphy.apiKey
        results = []
        error = nil
    }

    private func schedule(delay: Double) {
        task?.cancel()
        guard let key else { return }
        let query = self.query
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.loading = true
            do {
                let found = try await Giphy.fetch(query: query, key: key)
                guard !Task.isCancelled else { return }
                self.results = found
                self.error = found.isEmpty ? "No GIFs found." : nil
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach GIPHY."
            }
            self.loading = false
        }
    }
}

// MARK: Animated images

/// Downloads and caches GIFs so a message and the picker share one copy.
final class GifLoader {
    static let shared = GifLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var waiting: [URL: [(NSImage?) -> Void]] = [:]

    init() {
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    /// Calls back on the main queue.
    func load(_ url: URL, _ done: @escaping (NSImage?) -> Void) {
        if let image = cache.object(forKey: url as NSURL) {
            done(image)
            return
        }
        if waiting[url] != nil {
            waiting[url]?.append(done)
            return
        }
        waiting[url] = [done]
        let request = URLRequest(url: url)
        let finish: (NSImage?, Int) -> Void = { [weak self] image, cost in
            guard let self else { return }
            if let image { self.cache.setObject(image, forKey: url as NSURL, cost: cost) }
            let callbacks = self.waiting.removeValue(forKey: url) ?? []
            callbacks.forEach { $0(image) }
        }
        if url.isFileURL {
            let data = try? Data(contentsOf: url)
            finish(data.flatMap(NSImage.init(data:)), data?.count ?? 0)
            return
        }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { finish(image, data?.count ?? 0) }
        }.resume()
    }
}

/// An `NSImageView` that plays GIFs. Size it from SwiftUI; it has no size of its own.
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    var cornerRadius: CGFloat = 8

    final class View: NSImageView {
        var url: URL?
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        guard view.url != url else { return }
        view.url = url
        view.image = nil
        GifLoader.shared.load(url) { [weak view] image in
            guard let view, view.url == url else { return }
            view.image = image
            view.layer?.backgroundColor = image == nil ? NSColor.quaternaryLabelColor.cgColor : nil
        }
    }
}
