import Foundation
import Network

/// Reads the tailnet from the Tailscale CLI so parties can be joined with a click.
enum Tailscale {
    struct Device: Identifiable, Hashable {
        let name: String
        let address: String
        var id: String { address }
    }

    struct Status {
        let selfName: String?
        let selfAddress: String?
        let macs: [Device]
    }

    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func status() async -> Status? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: statusSync())
            }
        }
    }

    private static func statusSync() -> Status? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }

            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()

            guard process.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return parse(json)
        }
        return nil
    }

    private static func parse(_ json: [String: Any]) -> Status {
        func ipv4(_ node: [String: Any]) -> String? {
            (node["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
        }
        func name(_ node: [String: Any]) -> String? {
            if let dns = node["DNSName"] as? String, let first = dns.split(separator: ".").first {
                return String(first)
            }
            return node["HostName"] as? String
        }

        let me = json["Self"] as? [String: Any] ?? [:]
        let peers = (json["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        let macs = peers.compactMap { peer -> Device? in
            guard peer["Online"] as? Bool == true, peer["OS"] as? String == "macOS",
                  let address = ipv4(peer), let name = name(peer) else { return nil }
            return Device(name: name, address: address)
        }
        return Status(selfName: name(me), selfAddress: ipv4(me),
                      macs: macs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    /// Whether something is listening on the party port at `address`.
    static func isHosting(_ address: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let conn = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
            var finished = false
            let finish: (Bool) -> Void = { result in
                guard !finished else { return }
                finished = true
                conn.stateUpdateHandler = nil
                conn.cancel()
                continuation.resume(returning: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }
}

@MainActor
final class TailnetModel: ObservableObject {
    @Published var loaded = false
    @Published var available = false
    @Published var selfName: String?
    @Published var selfAddress: String?
    @Published var macs: [Tailscale.Device] = []
    @Published var hosting: Set<String> = []

    /// Also checks `also` (remembered party addresses) for a party.
    func refresh(port: UInt16, also extra: [String] = []) async {
        let status = await Tailscale.status()
        available = status != nil
        selfName = status?.selfName
        selfAddress = status?.selfAddress
        macs = status?.macs ?? []
        loaded = true

        await withTaskGroup(of: (String, Bool).self) { group in
            for address in Set(macs.map(\.address) + extra) {
                let (host, hostPort) = PartySession.parse(address, defaultPort: port)
                group.addTask { (address, await Tailscale.isHosting(host, port: hostPort)) }
            }
            var found: Set<String> = []
            for await (address, isHosting) in group where isHosting {
                found.insert(address)
            }
            hosting = found
        }
    }
}
