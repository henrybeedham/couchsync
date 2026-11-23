import Foundation
import Network

/// One message on the wire. Sent as a single line of JSON.
struct Wire: Codable {
    struct Member: Codable, Identifiable, Equatable {
        var id: String
        var name: String
    }

    /// Someone the party is waiting for, and why ("ad" or "buffering").
    struct Waiting: Codable, Equatable {
        var id: String
        var name: String
        var reason: String
    }

    /// hello | roster | state | sync | chat | history | react | float | hold | wait
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
    /// hold: "ad", "buffering", or nil when it's over. `pos` is where a buffering viewer is stuck.
    var reason: String?
    /// wait: everyone the party is waiting for (empty when it's over).
    var waiting: [Waiting]?
}

/// Something that carries bytes to one other Mac: TCP (Tailscale, LAN) or iroh (invite code).
/// Callbacks arrive on the main queue.
protocol Transport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func start()
    func send(_ data: Data)
    /// Stops without calling `onClose`.
    func cancel()
}

/// A TCP connection, for Macs that can reach each other directly (Tailscale, same network).
final class TCPTransport: Transport {
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let conn: NWConnection
    private var finished = false

    init(_ conn: NWConnection) {
        self.conn = conn
    }

    convenience init(host: String, port: NWEndpoint.Port) {
        self.init(NWConnection(host: NWEndpoint.Host(host), port: port, using: Self.parameters()))
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
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    func send(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        conn.stateUpdateHandler = nil
        conn.cancel()
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        cancel()
        onClose?(error)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.onData?(data)
            }
            guard !self.finished else { return }
            if isComplete || error != nil {
                self.finish(error)
            } else {
                self.receive()
            }
        }
    }
}

/// A connection to one other Mac, carrying newline-delimited `Wire` messages.
/// Everything runs on the main queue.
final class Link {
    let transport: Transport
    var peerId: String?
    var peerName: String?

    var onReady: (() -> Void)?
    var onMessage: ((Wire) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var buffer = Data()
    private var closed = false

    init(_ transport: Transport) {
        self.transport = transport
    }

    func start() {
        transport.onReady = { [weak self] in self?.onReady?() }
        transport.onData = { [weak self] data in
            guard let self, !self.closed else { return }
            self.buffer.append(data)
            self.drain()
        }
        transport.onClose = { [weak self] error in self?.close(error) }
        transport.start()
    }

    func send(_ message: Wire) {
        guard !closed, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        transport.send(data)
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        transport.cancel()
        onClose?(error)
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
