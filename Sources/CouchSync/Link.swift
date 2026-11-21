import Foundation
import Network

/// One message on the wire. Sent as a single line of JSON.
struct Wire: Codable {
    struct Member: Codable, Identifiable, Equatable {
        var id: String
        var name: String
    }

    /// hello | roster | state | sync | chat | history | react | float
    var t: String
    var id: String?
    var name: String?
    var videoId: String?
    var paused: Bool?
    var pos: Double?
    var seq: Int?
    var members: [Member]?
    var msg: ChatMessage?
    var history: [ChatMessage]?
    var msgId: String?
    var emoji: String?
    var on: Bool?
}

/// A TCP connection to one other Mac, carrying newline-delimited `Wire` messages.
/// Everything runs on the main queue.
final class Link {
    let conn: NWConnection
    var peerId: String?
    var peerName: String?

    var onReady: (() -> Void)?
    var onMessage: ((Wire) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var buffer = Data()
    private var closed = false

    init(_ conn: NWConnection) {
        self.conn = conn
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        return params
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let error), .waiting(let error):
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    func send(_ message: Wire) {
        guard !closed, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        conn.stateUpdateHandler = nil
        conn.cancel()
        onClose?(error)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.close(error)
            } else {
                self.receive()
            }
        }
    }

    private func drain() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let message = try? JSONDecoder().decode(Wire.self, from: line) {
                onMessage?(message)
                if closed { return }
            }
        }
        if buffer.count > 1_000_000 { close() }
    }
}
