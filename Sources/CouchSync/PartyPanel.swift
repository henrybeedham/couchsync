import SwiftUI

/// The popover behind the toolbar button: host, join, or see who's here.
struct PartyPanel: View {
    @EnvironmentObject private var session: PartySession
    @StateObject private var tailnet = TailnetModel()
    @AppStorage("displayName") private var name = ""
    @ViewState private var address = ""
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.mode {
            case .idle:
                idle
            case .connecting(let host):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.reconnecting ? "Reconnecting to \(host)…" : "Connecting to \(host)…")
                        if session.reconnectAttempt > 0 {
                            Text("Attempt \(session.reconnectAttempt + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Cancel") { session.leave() }
                }
            case .hosting:
                hosting
            case .joined(let host):
                joined(host)
            }

            if let error = session.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
        .task { await refresh() }
    }

    // MARK: Not in a party

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch together").font(.headline)
                Text("Play, pause and seek stay in step on every Mac in the party.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Your name", text: $name, prompt: Text(PartySession.defaultName))
                .textFieldStyle(.roundedBorder)

            Button {
                session.host()
            } label: {
                Text("Host a party").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Join a party").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Look again")
                }

                if !session.recents.isEmpty {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(session.recents) { party in
                            DeviceRow(name: party.name,
                                      detail: party.name == party.address ? nil : party.address,
                                      icon: "clock.arrow.circlepath",
                                      isHosting: tailnet.hosting.contains(party.address),
                                      onForget: { session.forget(party) }) {
                                session.join(party.address)
                            }
                        }
                    }
                    Text("On your tailnet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                if !tailnet.loaded {
                    Text("Looking for Macs on your tailnet…").font(.callout).foregroundStyle(.secondary)
                } else if !tailnet.available {
                    Text("Tailscale wasn't found. Enter an address below.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if otherMacs.isEmpty {
                    Text("No other Macs are online on your tailnet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(otherMacs) { mac in
                            DeviceRow(name: mac.name, isHosting: tailnet.hosting.contains(mac.address)) {
                                session.join(mac.address)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Hostname or IP", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { session.join(address) }
                    Button("Join") { session.join(address) }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Tailnet Macs that aren't already in the recent list.
    private var otherMacs: [Tailscale.Device] {
        tailnet.macs.filter { mac in
            !session.recents.contains { $0.address == mac.address || $0.address.caseInsensitiveCompare(mac.name) == .orderedSame }
        }
    }

    private func refresh() async {
        await tailnet.refresh(port: session.port, also: session.recents.map(\.address))
    }

    // MARK: In a party

    private var hosting: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're hosting", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)

            let shareAddress = tailnet.selfName ?? tailnet.selfAddress ?? ProcessInfo.processInfo.hostName
            VStack(alignment: .leading, spacing: 4) {
                Text("Others open CouchSync and pick this Mac, or join with:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(shareAddress)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shareAddress, forType: .string)
                        copied = true
                    }
                }
            }

            memberList(empty: "Waiting for someone to join…")

            Button("End party", role: .destructive) { session.leave() }
        }
    }

    private func joined(_ host: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're in a party", systemImage: "person.2.fill")
                .font(.headline)
            memberList(empty: "Connected to \(host).")
            Button("Leave party", role: .destructive) { session.leave() }
        }
    }

    @ViewBuilder
    private func memberList(empty: String) -> some View {
        if session.members.isEmpty {
            Text(empty).font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Watching with").font(.subheadline.weight(.semibold))
                ForEach(session.members) { member in
                    Label(member.name, systemImage: "person.crop.circle")
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let name: String
    var detail: String? = nil
    var icon = "desktopcomputer"
    let isHosting: Bool
    var onForget: (() -> Void)? = nil
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).lineLimit(1)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if isHosting {
                        Text("Hosting")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onForget, hovering {
                Button(action: onForget) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Forget")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
