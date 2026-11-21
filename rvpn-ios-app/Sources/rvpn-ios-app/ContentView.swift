import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var profileStore: ProfileStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ConnectView()
                .tabItem { Label("Connect", systemImage: "shield.fill") }
                .tag(0)

            ProfilesView()
                .tabItem { Label("Profiles", systemImage: "person.2.fill") }
                .tag(1)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(.green)
    }
}

// MARK: - Connect View

struct ConnectView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var profileStore: ProfileStore

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Profile picker
                if let profile = appState.selectedProfile ?? profileStore.defaultProfile {
                    VStack(spacing: 4) {
                        Text(profile.name)
                            .font(.headline)
                        Text(profile.serverAddress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                }

                // Connection status circle
                ZStack {
                    Circle()
                        .stroke(lineWidth: 4)
                        .frame(width: 140, height: 140)
                        .foregroundColor(appState.isConnected ? .green : .gray.opacity(0.3))

                    switch appState.connectionState {
                    case .disconnected:
                        Image(systemName: "shield.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                    case .connecting:
                        ProgressView()
                            .scaleEffect(1.5)
                    case .connected:
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                    case .disconnecting:
                        ProgressView()
                            .scaleEffect(1.5)
                    case .failed:
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 48))
                            .foregroundColor(.red)
                    }
                }
                .padding()

                // Status text
                switch appState.connectionState {
                case .disconnected:
                    Text("Not Connected").foregroundColor(.secondary)
                case .connecting:
                    Text("Connecting…").foregroundColor(.orange)
                case .connected(let ip, _):
                    VStack(spacing: 4) {
                        Text("Connected").foregroundColor(.green)
                        Text("IP: \(ip)").font(.caption).foregroundColor(.secondary)
                    }
                case .disconnecting:
                    Text("Disconnecting…").foregroundColor(.orange)
                case .failed(let error):
                    Text(error).foregroundColor(.red).multilineTextAlignment(.center)
                }

                // Connect/Disconnect button
                Button(action: {
                    if appState.isConnected {
                        appState.disconnect()
                    } else if let profile = appState.selectedProfile ?? profileStore.defaultProfile {
                        appState.connect(profile: profile)
                    }
                }) {
                    Text(appState.isConnected ? "Disconnect" : "Connect")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            appState.isConnected ? Color.red : Color.green
                        )
                        .cornerRadius(16)
                }
                .padding(.horizontal, 32)
                .disabled(
                    appState.connectionState == .connecting ||
                    appState.connectionState == .disconnecting
                )

                Spacer()
            }
            .navigationTitle("R-VPN")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Profiles View

struct ProfilesView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @State private var editingProfile: VPNProfile?
    @State private var showingNewProfile = false

    var body: some View {
        NavigationView {
            List {
                ForEach(profileStore.profiles) { profile in
                    Button(action: {
                        editingProfile = profile
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.name).font(.body.bold())
                                    if profile.isDefault {
                                        Image(systemName: "star.fill")
                                            .foregroundColor(.yellow)
                                            .font(.caption)
                                    }
                                }
                                Text(profile.serverAddress)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { indices in
                    profileStore.profiles.remove(atOffsets: indices)
                }
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingNewProfile = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewProfile) {
                ProfileEditorView(profile: VPNProfile(), isNew: true)
                    .environmentObject(profileStore)
            }
            .sheet(item: $editingProfile) { profile in
                ProfileEditorView(profile: profile, isNew: false)
                    .environmentObject(profileStore)
            }
        }
    }
}

// MARK: - Profile Editor

struct ProfileEditorView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) var dismiss

    @State var profile: VPNProfile
    let isNew: Bool

    var body: some View {
        NavigationView {
            Form {
                Section("Server") {
                    TextField("Profile name", text: $profile.name)
                    TextField("Server address (wss://…)", text: $profile.serverAddress)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }

                Section("Connection") {
                    Stepper("MTU: \(profile.mtu)", value: $profile.mtu, in: 1200...1500)
                    Toggle("Block ads", isOn: $profile.blockAds)
                    Toggle("Split tunnel", isOn: $profile.splitTunnelEnabled)
                }

                Section("DNS") {
                    ForEach(profile.dnsServers.indices, id: \.self) { i in
                        TextField("DNS server", text: $profile.dnsServers[i])
                            .keyboardType(.decimalPad)
                    }
                }

                if profile.splitTunnelEnabled {
                    Section("Bypass") {
                        TextField("Countries (IR,CN,…)", text: Binding(
                            get: { profile.bypassCountries.joined(separator: ",") },
                            set: { profile.bypassCountries = $0.split(",").map(String.init) }
                        ))
                    }
                }

                Section {
                    Toggle("Default profile", isOn: $profile.isDefault)
                }
            }
            .navigationTitle(isNew ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if isNew {
                            profileStore.profiles.append(profile)
                        } else if let idx = profileStore.profiles.firstIndex(where: { $0.id == profile.id }) {
                            profileStore.profiles[idx] = profile
                        }
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty || profile.serverAddress.isEmpty)
                }
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("startMinimized") private var startMinimized = false

    var body: some View {
        NavigationView {
            Form {
                Section("General") {
                    Toggle("Auto-connect on launch", isOn: $autoConnect)
                    Toggle("Start minimized", isOn: $startMinimized)
                }

                Section("About") {
                    LabeledRow("Version", "0.1.0")
                    LabeledRow("Engine", "rvpn-mobile (Rust)")
                    LabeledRow("Protocol", "X3DH + Double Ratchet")
                    LabeledRow("License", "AGPL-3.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
