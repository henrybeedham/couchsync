import AppKit
import Foundation

/// The services' own icons, for the Home screen, collected the way a browser
/// collects site icons: from the icons a service's pages list, either fetched
/// from its home page or read from its pages as you browse. Nothing is
/// bundled; icons are cached in Application Support and refreshed now and then.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private(set) var icons: [String: NSImage] = [:]

    private let folder: URL
    private var inFlight: Set<String> = []
    private static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    /// A link the page offered as an icon.
    struct Candidate {
        let url: URL
        let rel: String
        let size: Int

        /// Bigger is better; Apple touch icons are made for tiles like these.
        var score: Int {
            (rel.contains("apple-touch-icon") ? 10_000 : 0) + min(size, 1024)
                - (url.pathExtension.lowercased() == "svg" ? 100_000 : 0)
        }
    }

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CouchSync/Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for service in Services.all {
            if let image = NSImage(contentsOf: file(for: service)) { icons[service.id] = image }
        }
    }

    /// Fetches icons that are missing or old.
    func refresh() {
        for service in Services.all where isStale(service) {
            fetch(service)
        }
    }

    /// A page of `service` finished loading in the web view, offering these icons.
    func pageOffered(_ candidates: [Candidate], service: StreamingService) {
        // Also take the chance to replace a small icon with a sharper one.
        let small = (icons[service.id]?.size.width ?? 0) < 120
        guard isStale(service) || small else { return }
        download(candidates, for: service)
    }

    // MARK: Fetching

    private func isStale(_ service: StreamingService) -> Bool {
        guard icons[service.id] != nil,
              let date = (try? file(for: service).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { return true }
        return Date().timeIntervalSince(date) > Self.maxAge
    }

    private func fetch(_ service: StreamingService) {
        guard !inFlight.contains(service.id) else { return }
        inFlight.insert(service.id)
        Task {
            defer { inFlight.remove(service.id) }
            var request = URLRequest(url: service.home, timeoutInterval: 20)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let page = response.url,
                  service.owns(host: page.host),  // not redirected to another service
                  let html = String(data: data.prefix(3_000_000), encoding: .utf8)
                    ?? String(data: data.prefix(3_000_000), encoding: .isoLatin1) else { return }
            var candidates = Self.candidates(inHTML: html, base: page)
            if let fallback = URL(string: "/apple-touch-icon.png", relativeTo: page)?.absoluteURL {
                candidates.append(Candidate(url: fallback, rel: "apple-touch-icon", size: 0))
            }
            await downloadBest(candidates, for: service)
        }
    }

    private func download(_ candidates: [Candidate], for service: StreamingService) {
        guard !inFlight.contains(service.id) else { return }
        inFlight.insert(service.id)
        Task {
            defer { inFlight.remove(service.id) }
            await downloadBest(candidates, for: service)
        }
    }

    /// Tries the candidates, best first, until one is a usable image.
    private func downloadBest(_ candidates: [Candidate], for service: StreamingService) async {
        for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(4)
        where candidate.url.scheme == "https" {
            var request = URLRequest(url: candidate.url, timeoutInterval: 20)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 2_000_000,
                  let image = NSImage(data: data), image.isValid,
                  let png = Self.png(image, side: 256) else { continue }
            try? png.write(to: file(for: service), options: .atomic)
            icons[service.id] = NSImage(data: png)
            log("icon: \(service.id) from \(candidate.url.absoluteString)")
            return
        }
    }

    private func file(for service: StreamingService) -> URL {
        folder.appendingPathComponent("\(service.id).png")
    }

    /// Redraws the icon as a square PNG, so only plain image data is cached.
    /// Icons with a transparent background (favicons, mostly) get a dark
    /// backing, so they read on any tile, like an app icon.
    private static func png(_ image: NSImage, side: CGFloat) -> Data? {
        let best = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        let source = max(CGFloat(best?.pixelsWide ?? 0), image.size.width)
        guard source >= 16 else { return nil }
        let size = min(side, max(source, 64))
        func render(backing: Bool) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            let square = NSRect(x: 0, y: 0, width: size, height: size)
            if backing {
                NSColor(white: 0.08, alpha: 1).setFill()
                square.fill()
                // Favicons are drawn edge to edge; give them some room.
                image.draw(in: square.insetBy(dx: size * 0.16, dy: size * 0.16))
            } else {
                image.draw(in: square)
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        guard let plain = render(backing: false) else { return nil }
        let corners = [(0, 0), (Int(size) - 1, 0), (0, Int(size) - 1), (Int(size) - 1, Int(size) - 1)]
        let transparent = corners.contains { (plain.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.5 }
        let final = transparent ? (render(backing: true) ?? plain) : plain
        return final.representation(using: .png, properties: [:])
    }

    // MARK: Finding icons in a page

    static func candidates(inHTML html: String, base: URL) -> [Candidate] {
        guard let tag = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return tag.matches(in: html, range: range).compactMap { match in
            guard let r = Range(match.range, in: html) else { return nil }
            let text = String(html[r])
            func attribute(_ name: String) -> String? {
                let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
                for i in 1...3 {
                    if let rr = Range(m.range(at: i), in: text) { return String(text[rr]) }
                }
                return nil
            }
            guard let rel = attribute("rel")?.lowercased(), rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = attribute("href")?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }
            return Candidate(url: url, rel: rel, size: size(attribute("sizes")))
        }
    }

    /// "180x180" → 180.
    static func size(_ sizes: String?) -> Int {
        guard let sizes else { return 0 }
        return sizes.split(separator: " ").compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
    }

    /// Reads a loaded page's icon links (run in CouchSync's own script world).
    static let pageScript = """
    return [...document.querySelectorAll('link[rel~="icon"], link[rel~="apple-touch-icon"], link[rel="shortcut icon"], link[rel~="apple-touch-icon-precomposed"]')]
      .map((l) => ({ href: l.href, rel: (l.getAttribute('rel') || '').toLowerCase(), sizes: l.getAttribute('sizes') || '' }));
    """
}
