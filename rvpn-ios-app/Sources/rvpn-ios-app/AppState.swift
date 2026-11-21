import Foundation
import SwiftUI

// MARK: - Data Models

struct VPNProfile: Codable, Identifiable, Equatable {
    var id: String { UUID().uuidString }
    var name: String
    var serverAddress: String
    var identityKeyPath: String?
    var prekeyBundlePath: String?
    var dnsServers: [String]
    var mtu: Int
    var blockAds: Bool
    var splitTunnelEnabled: Bool
    var bypassCountries: [String]
    var bypassDomains: [String]
    var bypassNetworks: [String]
    var serverIdentityPin: String?
    var isDefault: Bool
    var createdAt: Date

    init(name: String = "New Profile") {
        self.name = name
        self.serverAddress = ""
        self.identityKeyPath = nil
        self.prekeyBundlePath = nil
        self.dnsServers = ["1.1.1.1", "8.8.8.8"]
        self.mtu = 1420
        self.blockAds = true
        self.splitTunnelEnabled = false
        self.bypassCountries = []
        self.bypassDomains = []
        self.bypassNetworks = []
        self.serverIdentityPin = nil
        self.isDefault = false
        self.createdAt = Date()
    }

    /// Convert to the JSON format the Rust engine expects (TunConfig).
    func engineConfig(identityPath: String, prekeyPath: String) -> [String: Any] {
        var config: [String: Any] = [
            "serverAddress": serverAddress,
            "identityKeyPath": identityPath,
            "prekeyBundlePath": prekeyPath,
            "dnsServers": dnsServers,
            "mtu": mtu,
            "blockAds": blockAds,
            "splitTunnelEnabled": splitTunnelEnabled,
            "enableDnsProxy": true,
            "dnsBindAddr": "127.0.0.1:53",
        ]
        if !bypassCountries.isEmpty {
            config["builtinBypassCountries"] = bypassCountries
        }
        if !bypassDomains.isEmpty {
            config["bypassDomains"] = bypassDomains
        }
        if !bypassNetworks.isEmpty {
            config["bypassNetworks"] = bypassNetworks
        }
        if let pin = serverIdentityPin {
            config["serverIdentityPin"] = pin
        }
        return config
    }
}

// MARK: - Profile Store

class ProfileStore: ObservableObject {
    @Published var profiles: [VPNProfile] = [] {
        didSet { save() }
    }

    private static var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profiles.json")
    }

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([VPNProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(profiles) else { return }
        try? encoded.write(to: Self.fileURL)
    }

    var defaultProfile: VPNProfile? {
        profiles.first(where: { $0.isDefault }) ?? profiles.first
    }
}

// MARK: - App State

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(ip: String, gateway: String)
    case disconnecting
    case failed(String)
}

class AppState: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var selectedProfile: VPNProfile?
    @Published var rxBytes: UInt64 = 0
    @Published var txBytes: UInt64 = 0
    @Published var connectedAt: Date?
    @Published var logLines: [String] = []
    @Published var tofuAlert: (expected: String, actual: String)?

    private var statsTimer: Timer?

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    func connect(profile: VPNProfile) {
        guard case .disconnected = connectionState else { return }
        selectedProfile = profile
        connectionState = .connecting

        // Ensure identity and prekey files exist
        let fm = FileManager.default
        let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let profileDir = docsDir.appendingPathComponent("profiles/\(profile.name)")
        try? fm.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let identityPath = profileDir.appendingPathComponent("identity.key").path
        let prekeyPath = profileDir.appendingPathComponent("prekey-bundle.json").path

        // Generate identity if not present
        if !fm.fileExists(atPath: identityPath) {
            if let identity = RustVPN.generateIdentity() {
                try? identity.write(toFile: identityPath, atomically: true, encoding: .utf8)
            }
        }

        // Build the engine config JSON
        let config = profile.engineConfig(identityPath: identityPath, prekeyPath: prekeyPath)
        guard let json = try? JSONSerialization.data(withJSONObject: config),
              let jsonStr = String(data: json, encoding: .utf8) else {
            connectionState = .failed("Failed to build engine config")
            return
        }

        // Initialize and connect
        RustVPN.initialize()
        RustVPN.setStateCallback { [weak self] state, ip, msg in
            DispatchQueue.main.async {
                self?.handleStateChange(Int32(state), ip: ip, msg: msg)
            }
        }

        guard RustVPN.tunCreate(configJSON: jsonStr) else {
            let err = RustVPN.lastError ?? "Unknown error"
            if err.contains("IDENTITY_MISMATCH") {
                let parts = err.components(separatedBy: " ")
                if parts.count >= 3 {
                    self.tofuAlert = (expected: parts[1], actual: parts[2])
                }
            }
            connectionState = .failed(err)
            return
        }

        guard RustVPN.tunStart() else {
            connectionState = .failed(RustVPN.lastError ?? "Start failed")
            return
        }

        startStatsTimer()
    }

    func disconnect() {
        guard isConnected else { return }
        connectionState = .disconnecting
        RustVPN.tunStop()
        RustVPN.tunDestroy()
        connectionState = .disconnected
        stopStatsTimer()
        connectedAt = nil
    }

    private func handleStateChange(_ state: Int32, ip: String, msg: String) {
        switch state {
        case 2: // IpAssigned
            break
        case 3: // Connected
            connectionState = .connected(
                ip: RustVPN.tunnelIP ?? ip,
                gateway: RustVPN.gatewayIP ?? ""
            )
            connectedAt = Date()
        case 4: // Error
            connectionState = .failed(msg)
        default:
            break
        }
    }

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            // TODO: read stats from engine
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
}
