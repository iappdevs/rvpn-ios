import Foundation
import NetworkExtension

/// Creates and drives the system VPN profile (Settings → VPN).
@MainActor
enum VPNManager {
    private static let tunnelBundleId = "org.rvpn.ios.tunnel"

    /// True when the packet-tunnel extension ships in this app bundle.
    static var extensionAvailable: Bool {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        let appex = plugIns.appendingPathComponent("RVPN Tunnel.appex", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: appex.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func existingManager() async throws -> NETunnelProviderManager? {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == tunnelBundleId
                }
                continuation.resume(returning: manager)
            }
        }
    }

    /// Save the profile and reload the same manager before starting its session.
    static func prepare(profile: Profile) async throws -> NETunnelProviderManager {
        let manager = try await existingManager() ?? NETunnelProviderManager()
        try Task.checkCancellation()
        if manager.connection.status != .disconnected, manager.connection.status != .invalid {
            return manager
        }

        // The extension stages its own files and writes their paths into the config.
        let identity = try String(contentsOf: ProfileStore.identityPath(profile.slug), encoding: .utf8)
        let prekey = try String(contentsOf: ProfileStore.prekeyPath(profile.slug), encoding: .utf8)
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.providerConfiguration = [
            "engineConfig": ProfileStore.engineConfig(for: profile),
            "identityKey": identity,
            "prekeyBundle": prekey,
        ]
        proto.serverAddress = profile.serverAddress
        proto.username = profile.name
        manager.protocolConfiguration = proto
        manager.localizedDescription = "R-VPN"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }
}
