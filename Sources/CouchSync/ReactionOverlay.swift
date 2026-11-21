import SwiftUI

/// Reactions rising up the right side of the video.
struct FloatingReactionsView: View {
    @EnvironmentObject private var chat: ChatModel

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: chat.floating.isEmpty)) { timeline in
                ZStack {
                    ForEach(chat.floating) { reaction in
                        bubble(reaction, now: timeline.date, in: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    private func bubble(_ reaction: FloatingReaction, now: Date, in size: CGSize) -> some View {
        let t = min(1, max(0, now.timeIntervalSince(reaction.start) / FloatingReaction.lifetime))
        let rise = min(size.height * 0.6, 520)
        let x = size.width - 70 - reaction.lane * 150 + sin(t * .pi * 2 * reaction.sway) * 16
        let y = size.height - 110 - t * rise
        let opacity = t < 0.08 ? t / 0.08 : (t > 0.7 ? (1 - t) / 0.3 : 1)
        let pop = 0.5 + min(1, t / 0.1) * 0.5

        return VStack(spacing: 2) {
            Text(reaction.emoji)
                .font(.system(size: 46))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            Text(reaction.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .scaleEffect(pop)
        .opacity(opacity)
        .position(x: x, y: y)
    }
}
