import SwiftUI

/// The Home screen: a smart-TV style launcher for the streaming services.
/// Arrow keys move between tiles and Return opens one, like a remote.
struct LauncherView: View {
    @EnvironmentObject private var web: WebController
    @EnvironmentObject private var session: PartySession
    @ObservedObject private var icons = IconStore.shared

    @ViewState private var selection = 0
    @FocusState private var focused: Bool

    private let services = Services.all

    var body: some View {
        GeometryReader { proxy in
            let columns = Self.columns(for: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    if session.inParty { partyChip }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: columns),
                              spacing: 22) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                            ServiceTile(service: service, icon: icons.icons[service.id],
                                        selected: index == selection) {
                                web.open(service)
                            }
                            .onHover { if $0 { selection = index } }
                        }
                    }
                    Text("Use the arrow keys and Return, like a remote.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
            }
            .scrollIndicators(.hidden)
            .background(background)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-columns) }
            .onKeyPress(.downArrow) { move(columns) }
            .onKeyPress(.return) {
                web.open(services[selection])
                return .handled
            }
        }
        .onAppear {
            icons.refresh()
            selection = services.firstIndex(of: web.service) ?? 0
            DispatchQueue.main.async { focused = true }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let next = selection + step
        guard services.indices.contains(next) else { return .handled }
        withAnimation(.spring(duration: 0.25)) { selection = next }
        return .handled
    }

    private static func columns(for width: CGFloat) -> Int {
        switch width {
        case ..<640: return 2
        case ..<980: return 3
        case ..<1380: return 4
        default: return 5
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.everyMinute) { context in
                    Text(Self.greeting(at: context.date))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                }
                Text("What are we watching?")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            TimelineView(.everyMinute) { context in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var partyChip: some View {
        let others = session.members.count
        return Label(others == 0 ? "Party is on: start something and everyone follows"
                                 : "In a party with \(others) other\(others == 1 ? "" : "s"): start something and everyone follows",
                     systemImage: "person.2.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.05, blue: 0.16), Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.45, green: 0.36, blue: 0.80).opacity(0.35), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }

    private static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

/// One service on the Home screen.
private struct ServiceTile: View {
    let service: StreamingService
    let icon: NSImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let style = TileStyle(service)
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                // A soft sheen across the top, like a lit panel.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
                VStack(alignment: .leading, spacing: 0) {
                    if let icon {
                        // The service's own icon, as its site provides it.
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    }
                    Spacer(minLength: 8)
                    Text(service.name)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(style.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(18)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.95 : 0.08), lineWidth: selected ? 3 : 1)
            )
            .shadow(color: style.colors[0].opacity(selected ? 0.55 : 0), radius: 22, y: 8)
            .scaleEffect(selected ? 1.06 : 1)
            .animation(.spring(duration: 0.25), value: selected)
        }
        .buttonStyle(.plain)
        .help("Open \(service.name)")
    }
}

/// Colours for each service's tile.
private struct TileStyle {
    let colors: [Color]
    let text: Color

    init(_ service: StreamingService) {
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
        }
        var text = Color.white
        switch service.id {
        case "netflix": colors = [rgb(0xE50914), rgb(0x5C0A0E)]
        case "disney": colors = [rgb(0x1F4FD8), rgb(0x0A1340)]
        case "prime": colors = [rgb(0x1AA7EC), rgb(0x0A3550)]
        case "max": colors = [rgb(0x6A3BF0), rgb(0x1A0F52)]
        case "appletv": colors = [rgb(0x4A4A50), rgb(0x0E0E10)]
        case "youtube": colors = [rgb(0xFF2D2D), rgb(0x7A0000)]
        case "iplayer": colors = [rgb(0xF54997), rgb(0x6E1645)]
        case "crunchyroll": colors = [rgb(0xF78B2D), rgb(0x8F3A06)]
        case "paramount": colors = [rgb(0x1A73FF), rgb(0x062A70)]
        case "hulu":
            colors = [rgb(0x1CE783), rgb(0x0C7A45)]
            text = rgb(0x06261A)
        default: colors = [rgb(0x7C63E6), rgb(0x241A5A)]
        }
        self.text = text
    }
}
