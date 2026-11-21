import CCouchNet
import Foundation

/// Joining by invite code, with no shared network: a thin layer over the iroh
/// bridge in net/. A Mac's invite code is its iroh endpoint id. iroh finds the
/// host, connects directly through both routers when it can, and goes through
/// n0's public relays when it can't. It's end-to-end encrypted either way.
/// Main thread only.
final class IrohNet {
    static let shared = IrohNet()

    /// This Mac's invite code. It stays the same between launches, so recent
    /// parties keep working.
    let code: String
    /// Someone dialed our invite code while we're hosting.
    var onIncoming: ((IrohTransport) -> Void)?

    fileprivate var transports: [UInt64: IrohTransport] = [:]

    private init() {
        var secret = Self.loadSecret()
        var buffer = [CChar](repeating: 0, count: 64)
        _ = cs_net_code_for_secret(&secret, &buffer, buffer.count)
        code = String(cString: buffer)
        log("invite code \(code)")
        if !cs_net_start(&secret, irohEvent, nil) {
            log("iroh didn't start")
        }
    }

    /// Kept in defaults rather than the keychain: it only identifies this Mac's party.
    private static func loadSecret() -> [UInt8] {
        let key = "irohSecretKey"
        if let saved = Debug.defaults.data(forKey: key), saved.count == 32 {
            return [UInt8](saved)
        }
        var secret = [UInt8](repeating: 0, count: 32)
        cs_net_generate_secret(&secret)
        Debug.defaults.set(Data(secret), forKey: key)
        return secret
    }

    var accepting = false {
        didSet { cs_net_set_accepting(accepting) }
    }

    /// Whether `text` is an invite code rather than a hostname or IP.
    static func isCode(_ text: String) -> Bool {
        cs_net_is_code(text)
    }

    /// The code as letters and digits only, however it was pasted.
    static func normalize(_ code: String) -> String {
        String(code.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// "abcd efgh …" groups of four, for reading out or eyeballing.
    static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { offset in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[start..<end])
        }.joined(separator: " ")
    }

    fileprivate func handle(conn: UInt64, kind: Int32, data: Data) {
        switch Int(kind) {
        case CS_EVENT_INCOMING:
            let transport = IrohTransport(incoming: conn)
            transports[conn] = transport
            if let onIncoming { onIncoming(transport) } else { transport.cancel() }
        case CS_EVENT_READY:
            transports[conn]?.ready()
        case CS_EVENT_DATA:
            transports[conn]?.onData?(data)
        case CS_EVENT_CLOSED:
            let reason = String(decoding: data, as: UTF8.self)
            transports.removeValue(forKey: conn)?.closed(reason)
        default:
            break
        }
    }
}

/// Called on iroh's threads. Copies the bytes, then hands them to the main thread.
private func irohEvent(_ ctx: UnsafeMutableRawPointer?, _ conn: UInt64, _ kind: Int32,
                       _ bytes: UnsafePointer<UInt8>?, _ len: Int) {
    let data = bytes.map { Data(bytes: $0, count: len) } ?? Data()
    DispatchQueue.main.async { IrohNet.shared.handle(conn: conn, kind: kind, data: data) }
}

struct IrohError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// One iroh connection, either one we dialed or one that dialed us.
final class IrohTransport: Transport {
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let code: String?
    private var conn: UInt64 = 0
    private var isReady = false
    private var finished = false

    init(dialing code: String) {
        self.code = code
    }

    fileprivate init(incoming conn: UInt64) {
        self.code = nil
        self.conn = conn
        self.isReady = true
    }

    func start() {
        if let code {
            conn = code.withCString { cs_net_connect($0) }
            guard conn != 0 else {
                DispatchQueue.main.async { self.closed("That isn't a valid invite code.") }
                return
            }
            IrohNet.shared.transports[conn] = self
        } else if isReady {
            onReady?()
        }
    }

    fileprivate func ready() {
        isReady = true
        onReady?()
    }

    func send(_ data: Data) {
        guard isReady, !finished else { return }
        data.withUnsafeBytes { buffer in
            cs_net_send(conn, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        if conn != 0 {
            cs_net_close(conn)
            IrohNet.shared.transports.removeValue(forKey: conn)
        }
    }

    fileprivate func closed(_ reason: String) {
        guard !finished else { return }
        finished = true
        onClose?(IrohError(reason: reason))
    }
}
