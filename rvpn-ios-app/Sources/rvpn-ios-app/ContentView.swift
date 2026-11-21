import SwiftUI
import UniformTypeIdentifiers

/// Root tab navigation (v2rayN-style): Connect, Profiles, Settings.
struct RootView: View {
    @StateObject private var state = AppState()

    var body: some View {
        TabView {
            ConnectView()
                .tabItem { Label("Connect", systemImage: "powerplug.fill") }
            ProfilesView()
                .tabItem { Label("Profiles", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .environmentObject(state)
    }
}

// MARK: - Connect

struct ConnectView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    if case .failed = state.connectionState {
                        errorCard
                    }
                    statsCard
                }
                .padding()
            }
            .navigationTitle("R-VPN")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var statusCard: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(statusColor)
                .frame(width: 88, height: 88)
                .overlay(
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                )
                .shadow(color: statusColor.opacity(0.5), radius: 12)

            Text(state.connectionState.label)
                .font(.title2.bold())

            if let profile = state.activeProfile {
                Text(profile.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No profile selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                if state.connectionState == .connected || state.connectionState == .connecting {
                    state.disconnect()
                } else if let profile = state.activeProfile {
                    state.connect(profile: profile)
                }
            } label: {
                Text(state.connectionState == .connected || state.connectionState == .connecting
                     ? "Disconnect" : "Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.connectionState == .connected ? .red : .blue)
            .disabled(state.activeProfile == nil)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(state.lastError ?? "Unknown error")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.orange.opacity(0.08)))
    }

    private var statsCard: some View {
        VStack(spacing: 12) {
            statRow("Server", value: state.serverIP ?? "—")
            statRow("Tunnel IP", value: state.tunnelIP ?? "—")
            statRow("Transferred", value: ByteCountFormatter.string(fromByteCount: Int64(state.transferredBytes), countStyle: .file))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }

    private var statusColor: Color {
        switch state.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @EnvironmentObject var state: AppState
    @State private var showingImporter = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(state.profiles) { profile in
                    Button {
                        state.activeProfileSlug = profile.slug
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.headline).foregroundStyle(.primary)
                                Text(profile.serverAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if state.activeProfileSlug == profile.slug {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                .onDelete(perform: state.deleteProfile)
            }
            .overlay {
                if state.profiles.isEmpty {
                    ContentUnavailableView(
                        "No Profiles",
                        systemImage: "tray",
                        description: Text("Import a .rvpn file exported from the server or the Windows client")
                    )
                }
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    importMessage = "Could not read the file"
                    return
                }
                switch ProfileStore.importDocument(text, existing: state.profiles) {
                case .success(let profile):
                    state.addProfile(profile)
                    importMessage = "Imported \(profile.name)"
                case .failure(let message):
                    importMessage = message
                }
            }
            .alert(
                "Import",
                isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    LabeledRow(label: "App", value: "R-VPN for iOS")
                    LabeledRow(label: "Engine", value: "rVPN-core (Rust)")
                    LabeledRow(label: "Version", value: appVersion)
                }
                Section("Engine Status") {
                    LabeledRow(label: "State", value: state.connectionState.label)
                    if let identity = activeServerIdentity {
                        LabeledRow(label: "Server identity", value: identity)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private var activeServerIdentity: String? {
        guard let profile = state.activeProfile else { return nil }
        return profile.serverIdentity.isEmpty ? nil : profile.serverIdentity
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}
