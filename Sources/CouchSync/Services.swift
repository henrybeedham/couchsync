import Foundation

/// A streaming site CouchSync knows how to follow.
///
/// The party identifies a title by a video ID that only CouchSync builds: the
/// service's ID, a colon and the title's ID from the page address (Netflix
/// titles keep their bare number, as in earlier versions). A peer can only
/// ever send us to `watchURL`, built here from an ID that matched `idPattern`.
struct StreamingService: Identifiable, Equatable {
    let id: String
    let name: String
    let home: URL
    /// Sites the service runs on, matched as the host or a subdomain of it.
    let domains: [String]
    /// Finds the title in a page address, or nil if it isn't a watch page.
    let titlePatterns: [String]
    /// What a title ID must look like, in full.
    let idPattern: String
    /// The page for a title.
    let watchPage: (String) -> String

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    func owns(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The title ID in `url`, if it's one of this service's watch pages.
    func titleId(in url: URL) -> String? {
        guard owns(host: url.host) else { return nil }
        var target = url.path
        if let query = url.query { target += "?" + query }
        for pattern in titlePatterns {
            guard let groups = Self.match(pattern, in: target) else { continue }
            let id = groups.joined(separator: "/")
            if Self.match(#"\A(?:"# + idPattern + #")\z"#, in: id) != nil { return id }
        }
        return nil
    }

    func watchURL(_ titleId: String) -> URL? {
        guard Self.match(#"\A(?:"# + idPattern + #")\z"#, in: titleId) != nil,
              let url = URL(string: watchPage(titleId)), owns(host: url.host) else { return nil }
        return url
    }

    /// Capture groups of the first match.
    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        if m.numberOfRanges == 1 { return [] }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }
}

enum Services {
    static let netflix = StreamingService(
        id: "netflix", name: "Netflix",
        home: URL(string: "https://www.netflix.com/browse")!,
        domains: ["netflix.com"],
        titlePatterns: [#"^/(?:[a-z]{2}(?:-[a-z]{2})?/)?watch/(\d+)"#],
        idPattern: #"\d{1,20}"#,
        watchPage: { "https://www.netflix.com/watch/\($0)" })

    static let all: [StreamingService] = [
        netflix,
        StreamingService(
            id: "disney", name: "Disney+",
            home: URL(string: "https://www.disneyplus.com/home")!,
            domains: ["disneyplus.com"],
            titlePatterns: [#"/(?:video|play)/([A-Za-z0-9-]{8,80})"#],
            idPattern: #"[A-Za-z0-9-]{8,80}"#,
            watchPage: { "https://www.disneyplus.com/play/\($0)" }),
        StreamingService(
            id: "prime", name: "Prime Video",
            home: URL(string: "https://www.primevideo.com/")!,
            domains: ["primevideo.com", "amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr",
                      "amazon.it", "amazon.es", "amazon.ca", "amazon.com.au", "amazon.co.jp", "amazon.in"],
            titlePatterns: [#"/(?:gp/video/)?(?:detail|dp)/(?:[^/?]+/)?(amzn1\.dv\.gti\.[0-9A-Fa-f-]{36}|[A-Z0-9]{10,24})(?:[/?]|$)"#],
            idPattern: #"amzn1\.dv\.gti\.[0-9A-Fa-f-]{36}|[A-Z0-9]{10,24}"#,
            watchPage: { "https://www.primevideo.com/detail/\($0)/?autoplay=1" }),
        StreamingService(
            id: "max", name: "HBO Max",
            home: URL(string: "https://play.hbomax.com/")!,
            domains: ["hbomax.com", "max.com"],
            titlePatterns: [#"/video/watch/([0-9A-Fa-f-]{36})(?:/([0-9A-Fa-f-]{36}))?"#],
            idPattern: #"[0-9A-Fa-f-]{36}(?:/[0-9A-Fa-f-]{36})?"#,
            watchPage: { "https://play.hbomax.com/video/watch/\($0)" }),
        StreamingService(
            id: "appletv", name: "Apple TV+",
            home: URL(string: "https://tv.apple.com/")!,
            domains: ["tv.apple.com"],
            titlePatterns: [#"^/(?:[a-z]{2}/)?(episode|movie)/([a-z0-9-]{1,120})/(umc\.cmc\.[a-z0-9]{10,40})"#],
            idPattern: #"(?:episode|movie)/[a-z0-9-]{1,120}/umc\.cmc\.[a-z0-9]{10,40}"#,
            watchPage: { "https://tv.apple.com/\($0)?action=play" }),
        StreamingService(
            id: "youtube", name: "YouTube",
            home: URL(string: "https://www.youtube.com/")!,
            domains: ["youtube.com"],
            titlePatterns: [#"^/watch\?(?:.*&)?v=([A-Za-z0-9_-]{11})"#, #"^/(?:shorts|live)/([A-Za-z0-9_-]{11})"#],
            idPattern: #"[A-Za-z0-9_-]{11}"#,
            watchPage: { "https://www.youtube.com/watch?v=\($0)" }),
        StreamingService(
            id: "iplayer", name: "BBC iPlayer",
            home: URL(string: "https://www.bbc.co.uk/iplayer")!,
            domains: ["bbc.co.uk"],
            titlePatterns: [#"^/iplayer/episode/([a-z0-9]{8})"#],
            idPattern: #"[a-z0-9]{8}"#,
            watchPage: { "https://www.bbc.co.uk/iplayer/episode/\($0)" }),
        StreamingService(
            id: "crunchyroll", name: "Crunchyroll",
            home: URL(string: "https://www.crunchyroll.com/")!,
            domains: ["crunchyroll.com"],
            titlePatterns: [#"^/(?:[a-z]{2}(?:-[a-z]{2})?/)?watch/([A-Z0-9]{6,12})"#],
            idPattern: #"[A-Z0-9]{6,12}"#,
            watchPage: { "https://www.crunchyroll.com/watch/\($0)" }),
        StreamingService(
            id: "paramount", name: "Paramount+",
            home: URL(string: "https://www.paramountplus.com/home/")!,
            domains: ["paramountplus.com"],
            titlePatterns: [#"/(shows|movies)/video/([A-Za-z0-9_-]{6,64})"#],
            idPattern: #"(?:shows|movies)/[A-Za-z0-9_-]{6,64}"#,
            watchPage: { id in
                let parts = id.split(separator: "/")
                return "https://www.paramountplus.com/\(parts[0])/video/\(parts[1])/"
            }),
        StreamingService(
            id: "hulu", name: "Hulu",
            home: URL(string: "https://www.hulu.com/hub/home")!,
            domains: ["hulu.com"],
            titlePatterns: [#"^/watch/([0-9A-Fa-f-]{36})"#],
            idPattern: #"[0-9A-Fa-f-]{36}"#,
            watchPage: { "https://www.hulu.com/watch/\($0)" }),
    ]

    static func service(id: String) -> StreamingService? { all.first { $0.id == id } }

    /// The service whose site `url` is on.
    static func service(for url: URL?) -> StreamingService? {
        guard let url else { return nil }
        return all.first { $0.owns(host: url.host) }
    }

    /// The party's ID for the title playing at `url`, if it's a watch page.
    static func videoId(for url: URL?) -> String? {
        guard let url, let service = service(for: url), let title = service.titleId(in: url) else { return nil }
        return service == netflix ? title : "\(service.id):\(title)"
    }

    /// Splits a party video ID into its service and title.
    static func parse(_ videoId: String) -> (StreamingService, String)? {
        if videoId.allSatisfy(\.isNumber) { return (netflix, videoId) }
        guard let colon = videoId.firstIndex(of: ":"),
              let service = service(id: String(videoId[..<colon])) else { return nil }
        return (service, String(videoId[videoId.index(after: colon)...]))
    }

    /// The only pages a peer can send us to.
    static func watchURL(for videoId: String) -> URL? {
        guard videoId.count <= 200, let (service, title) = parse(videoId) else { return nil }
        return service.watchURL(title)
    }

    /// Every domain a service runs on, for the page script's frame check.
    static var allDomains: [String] { all.flatMap(\.domains) }
}
