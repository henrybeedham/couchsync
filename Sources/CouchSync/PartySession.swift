import Foundation
import Network

func log(_ message: @autoclosure () -> String) {
    guard Debug.verbose else { return }
    FileHandle.standardError.write(Data("[couchsync] \(message())\n".utf8))
}

/// What the party agrees is on screen.
struct SharedState {
    var videoId: String
    var paused: Bool
    var pos: Double   // milliseconds
    var at: Date

    /// Position right now, assuming it kept playing since `at`.
    var currentPos: Double {
        paused ? pos : pos + Date().timeIntervalSince(at) * 1000
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// The party: one Mac hosts, the others connect to it, and the host relays.
///
/// Anyone can play, pause, seek or pick a title, and each such change bumps
/// `seq`. The host also sends its own position every couple of seconds so the
/// others can correct drift; a heartbeat older than the latest change is ignored.
final class PartySession: ObservableObject {
    enum Mode: Equatable {
        case idle
        case hosting
        case connecting(String)
        case joined(String)
    }

    static let defaultPort: UInt16 = 47800

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var members: [Wire.Member] = []
    @Published var lastError: String?
    @Published var toast: Toast?
    @Published private(set) var recents: [RecentParty] = PartySession.loadRecents()
    /// Trying to get back into a party after the connection dropped.
    @Published private(set) var reconnecting = false
    @Published private(set) var reconnectAttempt = 0

    weak var web: WebController?
    weak var chat: ChatModel?
    let port: UInt16
    let myId = UUID().uuidString

    var displayName: String {
        let saved = UserDefaults.standard.string(forKey: "displayName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? Self.defaultName : saved
    }

    static var defaultName: String {
        Debug.name ?? Host.current().localizedName ?? NSFullUserName()
    }

    private var listener: NWListener?
    private var links: [Link] = []
    private var shared: SharedState?
    private var seq = 0
    private var awaitingFirstRoster = false
    /// The address being joined, kept while reconnecting.
    private var target: String?
    private var quiet = false
    /// Back after a dropped connection: no "You joined" note.
    private var rejoined = false

    // Waiting for each other. A Mac that can't play along (a YouTube ad, or
    // stuck buffering) tells the host, which pauses the party until nobody is
    // held up, then plays again for everyone at once.
    struct Hold: Equatable {
        var videoId: String
        var reason: String
    }
    /// Why this Mac is holding the party up, if it is.
    private var localHold: Hold?
    private var localHoldPos: Double?
    /// Host only: who's holding the party up, by member id, and where they're stuck.
    private var holds: [String: (name: String, hold: Hold, pos: Double?)] = [:]
    /// Host only: holds someone chose not to wait for (they played, paused or
    /// seeked during the wait). Ignored until they're over.
    private var overridden: Set<String> = []
    /// Host only: the `seq` of the pause made to wait. The party plays again
    /// only if nobody has played, paused or seeked since.
    private var waitSeq: Int?
    /// Host only: where the party is waiting, to play from once everyone's ready.
    private var waitPos: Double = 0
    /// Who the party is waiting for, as last announced.
    @Published private(set) var waiting: [Wire.Waiting] = []

    init(port: UInt16 = PartySession.defaultPort) {
        self.port = port
        // Start iroh now so this Mac is reachable by its invite code as soon as it hosts.
        IrohNet.shared.onIncoming = { [weak self] transport in
            guard let self, self.isHosting else { transport.cancel(); return }
            self.accept(transport)
        }
    }

    /// The current party's invite code, for joining without Tailscale. New for every party.
    @Published private(set) var inviteCode: String?

    private var isHosting: Bool { mode == .hosting }

    var inParty: Bool {
        switch mode {
        case .hosting, .joined: return true
        default: return false
        }
    }

    /// True when someone else is actually in the party with us.
    private var hasCompany: Bool {
        switch mode {
        case .joined: return true
        case .hosting: return links.contains { $0.peerId != nil }
        default: return false
        }
    }

    // MARK: Starting and stopping

    func host() {
        leave(byUser: false)
        lastError = nil
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: TCPTransport.parameters(), on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(TCPTransport(conn)) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.leave(byUser: false)
                    self?.lastError = "Couldn't host: \(error.localizedDescription)"
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            inviteCode = IrohNet.shared.startHosting()
            mode = .hosting
            chat?.reset()
            chat?.system("You're hosting. Chat and reactions reach everyone who joins.")
            remember(last: "host")
            log("hosting on \(port)")
        } catch {
            lastError = "Couldn't host: \(error.localizedDescription)"
        }
    }

    /// Joins the party hosted at `address` ("name", "ip" or "name:port").
    /// With `quietly`, a party that isn't there fails without an error message.
    func join(_ address: String, quietly: Bool = false) {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if IrohNet.isCode(address) { address = IrohNet.normalize(address) }
        guard !address.isEmpty else { return }
        leave(byUser: false)
        lastError = nil
        target = address
        quiet = quietly
        reconnecting = quietly
        reconnectAttempt = 0
        connect(address, resuming: false)
    }

    /// Picks up where the last run left off: hosting again, or rejoining.
    func resume() {
        guard let last = Debug.defaults.string(forKey: "lastParty") else { return }
        if last == "host" {
            host()
        } else if last.hasPrefix("join:") {
            join(String(last.dropFirst(5)), quietly: true)
        }
    }

    func leave() {
        leave(byUser: true)
    }

    private func leave(byUser: Bool) {
        if inParty { chat?.system(isHosting ? "You ended the party." : "You left the party.") }
        if byUser { remember(last: nil) }
        target = nil
        quiet = false
        reconnecting = false
        reconnectAttempt = 0
        let old = links
        reset()
        old.forEach { $0.onClose = nil; $0.close() }
    }

    private func connect(_ address: String, resuming: Bool) {
        let byCode = IrohNet.isCode(address)
        let transport: Transport
        let hostPart: String
        if byCode {
            // Shown as "Connecting to the host…" until the roster names them.
            hostPart = "the host"
            transport = IrohTransport(dialing: address)
        } else {
            let (host, portPart) = Self.parse(address, defaultPort: port)
            guard let nwPort = NWEndpoint.Port(rawValue: portPart) else { return }
            hostPart = host
            transport = TCPTransport(host: host, port: nwPort)
        }

        let link = Link(transport)
        links = [link]
        mode = .connecting(hostPart)
        shared = nil
        seq = 0

        link.onReady = { [weak self, weak link] in
            guard let self, let link else { return }
            self.mode = .joined(hostPart)
            self.awaitingFirstRoster = true
            self.rejoined = resuming
            if resuming && !self.quiet {
                self.show("Reconnected")
            } else if !self.reconnecting {
                self.chat?.reset()
            }
            self.reconnecting = false
            self.reconnectAttempt = 0
            self.quiet = false
            self.remember(last: "join:" + address)
            link.send(Wire(t: "hello", id: self.myId, name: self.displayName))
            log("joined \(hostPart)")
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handle(message, from: link)
        }
        link.onClose = { [weak self, weak link] error in
            guard let self, let link, self.links.contains(where: { $0 === link }) else { return }
            let wasConnecting = { if case .connecting = self.mode { return true } else { return false } }()
            self.reset()
            log("link closed: \(String(describing: error))")
            guard self.target == address else { return }

            if !wasConnecting {
                // Dropped mid-party: the host may have restarted or the Wi-Fi blinked.
                self.reconnecting = true
                self.show("Connection lost. Reconnecting…")
                self.retry(address, host: hostPart)
            } else if self.reconnecting && self.reconnectAttempt < Self.maxReconnectAttempts {
                self.retry(address, host: hostPart)
            } else {
                let wasReconnecting = self.reconnecting && !self.quiet
                let silent = self.quiet
                self.target = nil
                self.reconnecting = false
                self.reconnectAttempt = 0
                self.quiet = false
                if silent { return }
                if wasReconnecting { self.chat?.system("Couldn't get back into the party.") }
                if byCode {
                    self.lastError = wasReconnecting
                        ? "Lost the party. \(hostPart) may have stopped hosting."
                        : "Couldn't reach the host. Check the invite code and that they're hosting."
                } else {
                    self.lastError = wasReconnecting
                        ? "Lost the party. \(hostPart) may have stopped hosting."
                        : "Couldn't reach \(hostPart). Is it hosting?"
                }
            }
        }
        link.start()

        // Finding a Mac by invite code and punching through both routers takes longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + (byCode ? 25 : 8)) { [weak self, weak link] in
            guard let self, let link, case .connecting = self.mode,
                  self.links.contains(where: { $0 === link }) else { return }
            link.close()
        }
    }

    private static let maxReconnectAttempts = 6

    /// Waits a little longer each time, then tries again.
    private func retry(_ address: String, host: String) {
        reconnectAttempt += 1
        mode = .connecting(host)
        let delay = min(8, pow(2, Double(reconnectAttempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.target == address, self.reconnecting, self.links.isEmpty else { return }
            self.connect(address, resuming: true)
        }
    }

    private func reset() {
        listener?.cancel()
        listener = nil
        if inviteCode != nil {
            IrohNet.shared.stopHosting()
            inviteCode = nil
        }
        links = []
        members = []
        holds = [:]
        overridden = []
        waitSeq = nil
        waiting = []
        awaitingFirstRoster = false
        mode = .idle
    }

    /// "name:port", leaving bare IPv6 addresses alone.
    static func parse(_ address: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
        if let colon = address.lastIndex(of: ":"), address.filter({ $0 == ":" }).count == 1,
           let parsed = UInt16(address[address.index(after: colon)...]) {
            return (String(address[..<colon]), parsed)
        }
        return (address, defaultPort)
    }

    // MARK: Remembering parties

    struct RecentParty: Codable, Identifiable, Equatable {
        var address: String
        var name: String
        var lastJoined: Date
        var id: String { address }
    }

    private static func loadRecents() -> [RecentParty] {
        guard let data = Debug.defaults.data(forKey: "recentParties"),
              let list = try? JSONDecoder().decode([RecentParty].self, from: data) else { return [] }
        // Invite codes only last one party; earlier builds saved them.
        return list.filter { !IrohNet.isCode($0.address) }
    }

    private func saveRecent(address: String, name: String) {
        var list = recents.filter { $0.address.caseInsensitiveCompare(address) != .orderedSame }
        list.insert(RecentParty(address: address, name: name, lastJoined: Date()), at: 0)
        recents = Array(list.prefix(6))
        Debug.defaults.set(try? JSONEncoder().encode(recents), forKey: "recentParties")
    }

    func forget(_ party: RecentParty) {
        recents.removeAll { $0 == party }
        Debug.defaults.set(try? JSONEncoder().encode(recents), forKey: "recentParties")
    }

    /// What to resume on next launch: "host", "join:<address>", or nothing.
    private func remember(last: String?) {
        if let last {
            Debug.defaults.set(last, forKey: "lastParty")
        } else {
            Debug.defaults.removeObject(forKey: "lastParty")
        }
    }

    // MARK: Host side

    private func accept(_ transport: Transport) {
        let link = Link(transport)
        links.append(link)
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handle(message, from: link)
        }
        link.onClose = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.links.removeAll { $0 === link }
            if let name = link.peerName {
                self.show("\(name) left")
                self.sendRoster()
            }
            if let id = link.peerId, self.holds.removeValue(forKey: id) != nil {
                self.overridden.remove(id)
                self.reconsiderWaiting()
            }
        }
        link.start()
    }

    private func sendRoster() {
        var all = [Wire.Member(id: myId, name: displayName)]
        for link in links {
            if let id = link.peerId, let name = link.peerName {
                all.append(Wire.Member(id: id, name: name))
            }
        }
        members = all.filter { $0.id != myId }
        let message = Wire(t: "roster", members: all)
        links.filter { $0.peerId != nil }.forEach { $0.send(message) }
    }

    // MARK: Messages

    private func handle(_ m: Wire, from link: Link) {
        switch m.t {
        case "hello":
            guard isHosting, let id = m.id else { return }
            link.peerId = id
            link.peerName = String((m.name ?? "Someone").prefix(40))
            if let history = chat?.history, !history.isEmpty {
                link.send(Wire(t: "history", history: history))
            }
            if let s = shared {
                link.send(Wire(t: "state", id: myId, videoId: s.videoId,
                               paused: s.paused, pos: s.currentPos, seq: seq))
            }
            sendRoster()
            if !waiting.isEmpty { link.send(Wire(t: "wait", waiting: waiting)) }
            show("\(link.peerName ?? "Someone") joined")

        case "roster":
            guard !isHosting else { return }
            let previous = members
            members = (m.members ?? []).filter { $0.id != myId }.map {
                Wire.Member(id: String($0.id.prefix(64)), name: String($0.name.prefix(40)))
            }
            // Invite codes only last one party, so there's no point remembering them.
            if awaitingFirstRoster, let target, !IrohNet.isCode(target) {
                // The host lists itself first.
                saveRecent(address: target, name: m.members?.first.map { String($0.name.prefix(40)) } ?? target)
            }
            if awaitingFirstRoster, !rejoined {
                let names = members.map(\.name)
                chat?.system(names.isEmpty ? "You joined the party." : "You joined \(Self.list(names)).")
            } else {
                for member in members where !previous.contains(where: { $0.id == member.id }) {
                    show("\(member.name) joined")
                }
                for member in previous where !members.contains(where: { $0.id == member.id }) {
                    show("\(member.name) left")
                }
            }
            if awaitingFirstRoster, let localHold {
                link.send(Wire(t: "hold", videoId: localHold.videoId, pos: localHoldPos, reason: localHold.reason))
            }
            if awaitingFirstRoster {
                awaitingFirstRoster = false
                // The host had nothing on; offer what we're watching instead.
                if shared == nil { web?.announce() }
            }

        case "state":
            guard let videoId = m.videoId, let paused = m.paused, let pos = m.pos,
                  let theirSeq = m.seq, theirSeq >= seq else { return }
            if isHosting, link.peerId == nil { return }
            let previous = shared
            seq = theirSeq
            let state = SharedState(videoId: videoId, paused: paused, pos: pos, at: Date())
            shared = state
            log("remote state \(videoId) paused=\(paused) pos=\(Int(pos)) seq=\(theirSeq)")
            web?.apply(state, force: true)
            if isHosting {
                relay(m, except: link)
                reconsiderWaiting()
            }
            if let name = m.name {
                show(Self.describe(name: name, state: state, previous: previous))
            }

        case "sync":
            guard !isHosting, let videoId = m.videoId, let paused = m.paused, let pos = m.pos,
                  let theirSeq = m.seq, theirSeq >= seq else { return }
            seq = theirSeq
            let state = SharedState(videoId: videoId, paused: paused, pos: pos, at: Date())
            shared = state
            web?.apply(state, force: false)

        case "hold":
            guard isHosting, let id = link.peerId, let name = link.peerName else { return }
            if let videoId = m.videoId, let reason = m.reason, ["ad", "buffering"].contains(reason) {
                holds[id] = (name, Hold(videoId: videoId, reason: reason), m.pos.flatMap { $0.isFinite ? $0 : nil })
            } else {
                holds[id] = nil
                overridden.remove(id)
            }
            reconsiderWaiting()

        case "wait":
            guard !isHosting, let list = m.waiting else { return }
            updateWaiting(Array(list.prefix(20)).map {
                Wire.Waiting(id: String($0.id.prefix(64)), name: String($0.name.prefix(40)),
                             reason: $0.reason == "ad" ? "ad" : "buffering")
            })

        case "history":
            guard !isHosting, let history = m.history else { return }
            chat?.load(history: history)

        case "chat":
            guard var message = m.msg else { return }
            if isHosting {
                // The host knows who is on each connection, so names can't be faked.
                guard let id = link.peerId, let name = link.peerName else { return }
                message.senderId = id
                message.senderName = name
                relay(Wire(t: "chat", msg: message), except: link)
            }
            chat?.receive(message)

        case "react":
            guard var id = m.id, var name = m.name, let msgId = m.msgId, let emoji = m.emoji, let on = m.on else { return }
            if isHosting {
                guard let peerId = link.peerId, let peerName = link.peerName else { return }
                (id, name) = (peerId, peerName)
                relay(Wire(t: "react", id: id, name: name, msgId: msgId, emoji: emoji, on: on), except: link)
            }
            chat?.applyReaction(messageId: msgId, emoji: emoji, on: on, by: id, name: name)

        case "float":
            guard var name = m.name, let emoji = m.emoji else { return }
            if isHosting {
                guard let peerName = link.peerName else { return }
                name = peerName
                relay(Wire(t: "float", id: link.peerId, name: name, emoji: emoji), except: link)
            }
            chat?.float(emoji, from: name)

        default:
            break
        }
    }

    /// Sends to everyone in the party: the host to all guests, a guest to the host.
    func broadcast(_ message: Wire) {
        links.filter { !isHosting || $0.peerId != nil }.forEach { $0.send(message) }
    }

    private func relay(_ message: Wire, except origin: Link) {
        links.filter { $0 !== origin && $0.peerId != nil }.forEach { $0.send(message) }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    // MARK: From the web view

    /// A video appeared. Returns the state it should adopt, or nil if it should
    /// carry on as it is and tell the party.
    func videoReady(_ videoId: String) -> SharedState? {
        guard hasCompany, let s = shared, s.videoId == videoId else { return nil }
        var current = s
        current.pos = s.currentPos
        current.at = Date()
        return current
    }

    func videoGone() {
        if !hasCompany { shared = nil }
    }

    /// The local viewer played, paused, seeked or opened a title.
    func localState(videoId: String, paused: Bool, pos: Double, reason: String) {
        seq += 1
        let previous = shared
        shared = SharedState(videoId: videoId, paused: paused, pos: pos, at: Date())
        log("local state (\(reason)) \(videoId) paused=\(paused) pos=\(Int(pos)) seq=\(seq)")
        if hasCompany, ["play", "pause", "seeked"].contains(reason), let shared {
            chat?.system(Self.describe(name: "You", state: shared, previous: previous))
        }
        broadcast(Wire(t: "state", id: myId, name: displayName, videoId: videoId,
                       paused: paused, pos: pos, seq: seq))
        if isHosting { reconsiderWaiting() }
    }

    // MARK: Waiting for each other

    /// This Mac started or stopped holding the party up (`reason` nil: stopped).
    func localHold(videoId: String?, reason: String?, pos: Double? = nil) {
        let hold = videoId.flatMap { id in reason.map { Hold(videoId: id, reason: $0) } }
        guard hold != localHold else { return }
        localHold = hold
        localHoldPos = pos
        log("local hold \(hold.map { "\($0.reason) on \($0.videoId)" } ?? "over")")
        switch mode {
        case .hosting:
            holds[myId] = hold.map { (displayName, $0, pos) }
            if hold == nil { overridden.remove(myId) }
            reconsiderWaiting()
        case .joined:
            links.first?.send(Wire(t: "hold", videoId: hold?.videoId, pos: pos, reason: hold?.reason))
        default:
            break
        }
    }

    /// The page moved on: a hold for another title is over.
    func pageChanged(videoId: String?) {
        if let localHold, localHold.videoId != videoId {
            self.localHold(videoId: nil, reason: nil)
        }
    }

    /// Host only: pauses the party when someone is newly held up, and plays it
    /// again once nobody is (unless someone took over in the meantime).
    private func reconsiderWaiting() {
        guard isHosting else { return }
        let videoId = shared?.videoId
        // Only holds on the title the party is watching, and only with company.
        var active = hasCompany ? holds.filter { $0.value.hold.videoId == videoId } : [:]
        // Someone played, paused or seeked during the wait: they've decided
        // not to wait, so stop waiting for whoever was holding things up then.
        if let waitSeq, waitSeq != seq {
            overridden.formUnion(active.keys)
            self.waitSeq = nil
        }
        active = active.filter { !overridden.contains($0.key) }
        let list = active.map { Wire.Waiting(id: $0.key, name: $0.value.name, reason: $0.value.hold.reason) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if !list.isEmpty, waiting.isEmpty, let s = shared, !s.paused {
            // Wait where the furthest-behind buffering viewer is stuck, so
            // they don't miss anything (everyone else rewinds a moment).
            var pos = s.currentPos
            for stuck in active.values.compactMap(\.pos) where stuck < pos && pos - stuck < 30_000 {
                pos = stuck
            }
            setPartyState(paused: true, pos: pos, videoId: s.videoId)
            waitSeq = seq
            waitPos = pos
            log("waiting for \(list.map(\.name))")
        } else if list.isEmpty, !waiting.isEmpty {
            if let waitSeq, waitSeq == seq, let s = shared {
                setPartyState(paused: false, pos: waitPos, videoId: s.videoId)
                log("everyone's ready")
            }
            waitSeq = nil
        }
        guard list != waiting else { return }
        updateWaiting(list)
        let message = Wire(t: "wait", waiting: list)
        links.filter { $0.peerId != nil }.forEach { $0.send(message) }
    }

    /// Host only: plays or pauses everyone, the host's own player included.
    private func setPartyState(paused: Bool, pos: Double, videoId: String) {
        seq += 1
        let state = SharedState(videoId: videoId, paused: paused, pos: pos, at: Date())
        shared = state
        web?.apply(state, force: true)
        // No name: the wait note says what's going on, not "Host paused".
        let message = Wire(t: "state", id: myId, videoId: videoId, paused: paused, pos: pos, seq: seq)
        links.filter { $0.peerId != nil }.forEach { $0.send(message) }
    }

    /// The window shows `waiting` for as long as it lasts.
    private func updateWaiting(_ list: [Wire.Waiting]) {
        waiting = list
    }

    /// What the window says while the party waits.
    var waitingText: String? {
        waiting.isEmpty ? nil : Self.waitingText(waiting, me: myId)
    }

    static func waitingText(_ waiting: [Wire.Waiting], me: String) -> String {
        if waiting.count == 1, let w = waiting.first {
            if w.id == me {
                return w.reason == "ad" ? "The party is waiting for your ad to finish" : "The party is waiting for you to catch up"
            }
            return (w.reason == "ad" ? "Waiting for \(w.name)'s ad to finish" : "Waiting for \(w.name) to catch up")
                + ". Press play to go without them."
        }
        let names = waiting.map { $0.id == me ? "you" : $0.name }
        return "Waiting for \(list(names)). Press play to go without them."
    }

    /// Periodic position report from the local player.
    func localTick(videoId: String, paused: Bool, pos: Double) {
        log("tick \(videoId) paused=\(paused) pos=\(Int(pos))")
        switch mode {
        case .idle:
            shared = SharedState(videoId: videoId, paused: paused, pos: pos, at: Date())
        case .hosting:
            // Don't let our old page overwrite a title the party just switched to.
            if hasCompany, let s = shared, s.videoId != videoId { return }
            // While waiting for someone the party stays paused where it is,
            // even if our own player hasn't caught up with that yet.
            if waitSeq != nil { return }
            shared = SharedState(videoId: videoId, paused: paused, pos: pos, at: Date())
            let message = Wire(t: "sync", id: myId, videoId: videoId, paused: paused, pos: pos, seq: seq)
            links.filter { $0.peerId != nil }.forEach { $0.send(message) }
        default:
            break
        }
    }

    // MARK: Toasts

    /// A note in the chat, and a toast over the video if the chat is hidden.
    func show(_ text: String) {
        chat?.system(text)
        if chat?.isVisible != true { toast = Toast(text: text) }
    }

    /// A toast only, for things that aren't part of the party's story.
    func warn(_ text: String) {
        toast = Toast(text: text)
    }

    private static func describe(name: String, state: SharedState, previous: SharedState?) -> String {
        let time = timestamp(state.pos)
        guard let previous, previous.videoId == state.videoId else {
            guard let service = Services.parse(state.videoId)?.0 else { return "\(name) started a title" }
            return "\(name) started a title on \(service.name)"
        }
        if previous.paused != state.paused {
            return state.paused ? "\(name) paused at \(time)" : "\(name) pressed play at \(time)"
        }
        return "\(name) jumped to \(time)"
    }

    static func timestamp(_ ms: Double) -> String {
        let total = max(0, Int(ms / 1000))
        let (h, m, s) = (total / 3600, (total / 60) % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
