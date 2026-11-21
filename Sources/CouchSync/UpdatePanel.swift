import SwiftUI

/// The sheet for "Check for Updates…" and the toolbar's Update button.
struct UpdatePanel: View {
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var session: PartySession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let release = updater.latest, updater.hasUpdate || updater.phase == .installing {
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(markdown(release.notes))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 160)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if updater.hasUpdate, let reason = updater.cannotInstall {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Toggle("Install updates automatically", isOn: $updater.automatic)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        switch updater.phase {
        case .checking: return "Checking for updates…"
        case .upToDate, .idle: return "CouchSync is up to date"
        case .available, .downloading: return "CouchSync \(updater.latest?.version ?? "") is available"
        case .ready: return "CouchSync \(updater.latest?.version ?? "") is ready to install"
        case .installing: return "Installing…"
        case .failed: return "Update problem"
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case .checking: return "You have version \(updater.current)."
        case .upToDate, .idle: return "You have the latest version, \(updater.current)."
        case .available: return "You have version \(updater.current)."
        case .downloading: return "Downloading…"
        case .ready:
            let party = session.inParty ? " You'll rejoin the party when it opens again." : ""
            return "It installs when you quit CouchSync, or restart now.\(party)"
        case .installing: return "CouchSync will reopen in a moment."
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.phase {
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        case .available:
            Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            if updater.cannotInstall == nil {
                Button("Download") { updater.download() }.keyboardShortcut(.defaultAction)
            } else if let page = updater.latest?.page {
                Button("Open Download Page") { NSWorkspace.shared.open(page); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        case .ready:
            Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            // Deliberately not on Return: a restart shouldn't happen by accident.
            Button("Restart Now") { updater.restartToUpdate() }.buttonStyle(.borderedProminent)
        case .failed:
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Try Again") {
                if updater.latest != nil { updater.download() } else { updater.check(userInitiated: true) }
            }
            .keyboardShortcut(.defaultAction)
        case .upToDate, .idle:
            Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Toolbar button shown while an update is waiting.
struct UpdateButton: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        if updater.hasUpdate {
            Button { updater.showPanel = true } label: {
                Label(updater.phase == .ready ? "Restart to Update" : "Update", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
            }
            .help("CouchSync \(updater.latest?.version ?? "") is available")
        }
    }
}

/// CouchSync → Settings…
struct SettingsView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Download and install updates automatically", isOn: $updater.automatic)
                LabeledContent("Version", value: updater.current)
                LabeledContent("Last checked") {
                    Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
                Button("Check Now") { updater.check(userInitiated: true) }
                    .disabled(updater.isBusy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
