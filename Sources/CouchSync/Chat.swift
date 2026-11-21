import Foundation
import SwiftUI

/// One line in the chat. Text, a GIF, or a local system note ("Sam paused at 12:04").
struct ChatMessage: Codable, Identifiable, Equatable {
    struct Gif: Codable, Equatable {
        var url: String
        var width: Double
        var height: Double
        var title: String?
    }

    var id: String
    var senderId: String
    var senderName: String
    var text: String?
    var gif: Gif?
    var date: Date
    /// emoji -> (member id -> name)
    var reactions: [String: [String: String]] = [:]
    /// System notes are made locally by each Mac and never sent.
    var isSystem = false

    /// Drops anything malformed or unsafe that arrived from another Mac.
    func sanitized() -> ChatMessage? {
        guard !id.isEmpty, id.count <= 64, !senderId.isEmpty, senderId.count <= 64 else { return nil }
        var m = self
        m.senderName = String(senderName.prefix(40))
        m.isSystem = false
        m.text = text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatModel.maxLength)) }
        if m.text?.isEmpty == true { m.text = nil }
        if let gif = m.gif, !Giphy.isAllowedMedia(gif.url) || !(gif.width > 0 && gif.height > 0) { m.gif = nil }
        guard m.text != nil || m.gif != nil else { return nil }
        m.reactions = reactions.filter { Reactions.palette.contains($0.key) }
            .mapValues { $0.filter { $0.key.count <= 64 }.mapValues { String($0.prefix(40)) } }
            .filter { !$0.value.isEmpty }
        return m
    }
}

enum Reactions {
    static let palette = ["😂", "😮", "😍", "😢", "👏", "🔥", "💀", "🍿"]
}

/// An emoji drifting up over the video.
struct FloatingReaction: Identifiable {
    let id = UUID()
    let emoji: String
    let name: String
    let start = Date()
    /// 0...1, where across the lane it rises.
    let lane = Double.random(in: 0...1)
    let sway = Double.random(in: 0.6...1.4)

    static let lifetime: TimeInterval = 3.2
}

/// The party's chat and reactions. Talks to the network through `PartySession`.
final class ChatModel: ObservableObject {
    static let maxLength = 1000
    static let maxMessages = 500

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var floating: [FloatingReaction] = []
    @Published private(set) var unread = 0
    @Published var draft = ""
    @Published var gifPickerOpen = false
    @Published var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: "chatVisible")
            if isVisible { unread = 0 }
        }
    }

    weak var session: PartySession?

    init() {
        isVisible = UserDefaults.standard.object(forKey: "chatVisible") as? Bool ?? true
    }

    var myId: String { session?.myId ?? "" }
    var canSend: Bool { session?.inParty ?? false }

    // MARK: Sending

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }
        draft = ""
        send(text: String(text.prefix(Self.maxLength)), gif: nil)
    }

    func send(gif: ChatMessage.Gif) {
        guard canSend else { return }
        gifPickerOpen = false
        send(text: nil, gif: gif)
    }

    private func send(text: String?, gif: ChatMessage.Gif?) {
        guard let session else { return }
        let message = ChatMessage(id: UUID().uuidString, senderId: session.myId, senderName: session.displayName,
                                  text: text, gif: gif, date: Date())
        append(message)
        session.broadcast(Wire(t: "chat", msg: message))
    }

    func toggleReaction(_ emoji: String, on messageId: String) {
        guard let session, canSend, let message = messages.first(where: { $0.id == messageId }) else { return }
        let on = message.reactions[emoji]?[session.myId] == nil
        applyReaction(messageId: messageId, emoji: emoji, on: on, by: session.myId, name: session.displayName)
        session.broadcast(Wire(t: "react", id: session.myId, name: session.displayName,
                               msgId: messageId, emoji: emoji, on: on))
    }

    func sendFloating(_ emoji: String) {
        guard let session, canSend, Reactions.palette.contains(emoji) else { return }
        float(emoji, from: "You")
        session.broadcast(Wire(t: "float", id: session.myId, name: session.displayName, emoji: emoji))
    }

    // MARK: Receiving

    func receive(_ message: ChatMessage) {
        guard let clean = message.sanitized(), !messages.contains(where: { $0.id == clean.id }) else { return }
        append(clean)
        if !isVisible { unread += 1 }
    }

    func load(history: [ChatMessage]) {
        let known = Set(messages.map(\.id))
        let incoming = history.suffix(Self.maxMessages).compactMap { $0.sanitized() }.filter { !known.contains($0.id) }
        // History is older than anything said since we arrived.
        messages = Array((incoming + messages).suffix(Self.maxMessages))
    }

    func applyReaction(messageId: String, emoji: String, on: Bool, by memberId: String, name: String) {
        guard Reactions.palette.contains(emoji), memberId.count <= 64,
              let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var reactors = messages[index].reactions[emoji] ?? [:]
        reactors[memberId] = on ? String(name.prefix(40)) : nil
        messages[index].reactions[emoji] = reactors.isEmpty ? nil : reactors
    }

    func float(_ emoji: String, from name: String) {
        guard Reactions.palette.contains(emoji) else { return }
        // A burst of clicks shouldn't bury the video.
        if floating.count >= 30 { floating.removeFirst() }
        let reaction = FloatingReaction(emoji: emoji, name: String(name.prefix(40)))
        floating.append(reaction)
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatingReaction.lifetime + 0.1) { [weak self] in
            self?.floating.removeAll { $0.id == reaction.id }
        }
    }

    // MARK: Local notes

    func system(_ text: String) {
        append(ChatMessage(id: UUID().uuidString, senderId: "", senderName: "", text: text,
                           date: Date(), isSystem: true))
    }

    func reset() {
        messages = []
        floating = []
        unread = 0
        gifPickerOpen = false
    }

    /// What a newcomer is sent: everything but system notes.
    var history: [ChatMessage] {
        Array(messages.filter { !$0.isSystem }.suffix(200))
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
    }

    // MARK: Display helpers

    static func color(for memberId: String) -> Color {
        let colors: [Color] = [.pink, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple]
        let hash = memberId.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        return colors[Int(hash % UInt32(colors.count))]
    }
}
