import SwiftUI

/// The sidebar: messages, GIFs, reactions.
struct ChatPanel: View {
    @EnvironmentObject private var chat: ChatModel
    @EnvironmentObject private var session: PartySession
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat.messages.isEmpty && !chat.canSend {
                placeholder
            } else {
                MessageList()
            }
            Divider()
            if chat.gifPickerOpen {
                GifPicker()
                Divider()
            }
            ReactionBar()
            Composer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Chat").font(.headline)
            Spacer()
            HStack(spacing: -6) {
                ForEach(session.members.prefix(5)) { member in
                    Avatar(name: member.name, memberId: member.id, size: 22)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .help(member.name)
                }
            }
            if session.inParty {
                Text(session.members.isEmpty ? "Just you" : "\(session.members.count + 1) watching")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { chat.isVisible = false }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .help("Hide chat (⇧⌘C)")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Chat with your party").font(.headline)
            Text("Messages, GIFs and reactions show up for everyone watching.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start or join a party") { app.showParty = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Messages

private struct MessageList: View {
    @EnvironmentObject private var chat: ChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message, startsGroup: startsGroup(index))
                            .id(message.id)
                    }
                }
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func startsGroup(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chat.messages[index - 1]
        let message = chat.messages[index]
        return previous.isSystem || previous.senderId != message.senderId
            || message.date.timeIntervalSince(previous.date) > 300
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let startsGroup: Bool
    @EnvironmentObject private var chat: ChatModel
    @ViewState private var hovering = false

    private var mine: Bool { message.senderId == chat.myId }

    var body: some View {
        Group {
            if message.isSystem {
                Text(message.text ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .help(Self.time.string(from: message.date))
            } else {
                bubbleRow
                    .padding(.top, startsGroup ? 8 : 2)
            }
        }
        .zIndex(hovering ? 1 : 0)
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine {
                Spacer(minLength: 48)
            } else if startsGroup {
                Avatar(name: message.senderName, memberId: message.senderId, size: 28)
            } else {
                Color.clear.frame(width: 28, height: 1)
            }

            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if startsGroup && !mine {
                    Text(message.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChatModel.color(for: message.senderId))
                }
                content
                    .overlay(alignment: mine ? .topLeading : .topTrailing) {
                        if hovering && chat.canSend {
                            QuickReactions(messageId: message.id)
                                .offset(x: mine ? -8 : 8, y: -22)
                                .transition(.opacity)
                        }
                    }
                    .help(Self.time.string(from: message.date))
                if !message.reactions.isEmpty {
                    ReactionChips(message: message)
                }
            }

            if !mine { Spacer(minLength: 32) }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.1)) { hovering = inside } }
    }

    @ViewBuilder
    private var content: some View {
        if let gif = message.gif, let url = URL(string: gif.url) {
            let width = min(220, max(120, gif.width))
            AnimatedImage(url: url, cornerRadius: 12)
                .frame(width: width, height: width * gif.height / gif.width)
                .accessibilityLabel(gif.title ?? "GIF")
        } else if let text = message.text {
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .background(mine ? Color.accentColor : Color.primary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

private struct QuickReactions: View {
    let messageId: String
    @EnvironmentObject private var chat: ChatModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Reactions.palette, id: \.self) { emoji in
                EmojiButton(emoji: emoji, size: 15) { chat.toggleReaction(emoji, on: messageId) }
            }
        }
        .padding(.horizontal, 3)
        .glassCapsule()
        .fixedSize()
    }
}

private struct ReactionChips: View {
    let message: ChatMessage
    @EnvironmentObject private var chat: ChatModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sorted, id: \.emoji) { item in
                let mine = item.reactors[chat.myId] != nil
                Button {
                    chat.toggleReaction(item.emoji, on: message.id)
                } label: {
                    HStack(spacing: 3) {
                        Text(item.emoji)
                        Text("\(item.reactors.count)").font(.caption.weight(.medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(mine ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(mine ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .help(item.reactors.keys.sorted().map { $0 == chat.myId ? "You" : item.reactors[$0]! }
                    .joined(separator: ", "))
            }
        }
    }

    private var sorted: [(emoji: String, reactors: [String: String])] {
        message.reactions
            .map { (emoji: $0.key, reactors: $0.value) }
            .sorted { (Reactions.palette.firstIndex(of: $0.emoji) ?? 99) < (Reactions.palette.firstIndex(of: $1.emoji) ?? 99) }
    }
}

// MARK: Composer and reactions

private struct ReactionBar: View {
    @EnvironmentObject private var chat: ChatModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Reactions.palette, id: \.self) { emoji in
                EmojiButton(emoji: emoji, size: 20) { chat.sendFloating(emoji) }
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .disabled(!chat.canSend)
        .opacity(chat.canSend ? 1 : 0.4)
        .help("Send a reaction over the video")
    }
}

private struct Composer: View {
    @EnvironmentObject private var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { chat.gifPickerOpen.toggle() }
            } label: {
                Text("GIF")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(chat.gifPickerOpen ? Color.white : Color.secondary)
                    .background(chat.gifPickerOpen ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(chat.gifPickerOpen ? .clear : Color.secondary, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help("Send a GIF")

            TextField(chat.canSend ? "Message" : "Join a party to chat", text: $chat.draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    chat.sendDraft()
                    focused = true
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                chat.sendDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
            .disabled(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .disabled(!chat.canSend)
    }
}

// MARK: GIF browser

private struct GifPicker: View {
    @EnvironmentObject private var chat: ChatModel
    @StateObject private var search = GifSearch()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if search.key == nil {
                KeySetup(search: search)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search GIPHY", text: $search.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onExitCommand { chat.gifPickerOpen = false }
                    if search.loading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        chat.gifPickerOpen = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                ScrollView {
                    if let error = search.error {
                        VStack(spacing: 8) {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                            if error == Giphy.Failure.badKey.errorDescription {
                                Button("Use a different key") { search.forgetKey() }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        masonry
                    }
                }
                .frame(height: 280)

                HStack {
                    Text(search.query.isEmpty ? "Trending" : "Results")
                    Spacer()
                    Text("Powered by GIPHY")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .onAppear {
            search.start()
            focused = true
        }
    }

    /// Two columns, each GIF added to whichever is shorter.
    private var masonry: some View {
        var columns: [[Giphy.Result]] = [[], []]
        var heights: [Double] = [0, 0]
        for result in search.results {
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(result)
            heights[column] += result.gif.height / result.gif.width
        }
        return HStack(alignment: .top, spacing: 6) {
            ForEach(0..<2, id: \.self) { column in
                VStack(spacing: 6) {
                    ForEach(columns[column]) { result in
                        Button {
                            chat.send(gif: result.gif)
                        } label: {
                            AnimatedImage(url: result.preview, cornerRadius: 6)
                                .aspectRatio(result.gif.width / result.gif.height, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .help(result.title)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

private struct KeySetup: View {
    @ObservedObject var search: GifSearch
    @ViewState private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GIFs come from GIPHY").font(.subheadline.weight(.semibold))
            Text("Paste a free API key to turn them on. Create an app at developers.giphy.com and choose API.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SwiftUI.Link("Get a key at developers.giphy.com", destination: URL(string: "https://developers.giphy.com/dashboard/")!)
                .font(.callout)
            HStack {
                TextField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search.save(key: key) }
                Button("Save") { search.save(key: key) }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: Small pieces

struct Avatar: View {
    let name: String
    let memberId: String
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(ChatModel.color(for: memberId).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.first ?? "?").uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

private struct EmojiButton: View {
    let emoji: String
    let size: CGFloat
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: size))
                .scaleEffect(hovering ? 1.25 : 1)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.spring(duration: 0.2)) { hovering = inside } }
    }
}
