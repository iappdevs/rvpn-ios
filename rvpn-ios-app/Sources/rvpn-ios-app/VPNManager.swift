import Foundation
import NetworkExtension
import os

/// Creates and drives the system VPN profile (Settings → VPN).
enum VPNManager {
    private static let tunnelBundleId = "org.rvpn.ios.tunnel"

    /// True only when the packet-tunnel extension binary ships in the app
    /// bundle (PlugIns/RVPN Tunnel.appex). Until the XcodeGen project lands
    /// the appex is absent and every connect must use the in-app engine.
    static var extensionAvailable: Bool {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        let appex = plugIns.appendingPathComponent("RVPN Tunnel.appex", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: appex.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Load (or create) our tunnel configuration, then bring the tunnel up.
    static func connect(profile: Profile, completion: @escaping (String?) -> Void) {
        guard extensionAvailable else {
            os_log("[RVPN] tunnel appex not embedded — in-app engine path", type: .info)
            completion("no appex")
            return
        }
        let configJSON = ProfileStore.engineConfig(for: profile)
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                os_log("[RVPN] load VPN prefs failed: %{public}@", type: .error, "\(error)")
                completion("\(error.localizedDescription)")
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            // The extension lives in its own sandbox and cannot read the
            // app container — hand it the identity/prekey contents directly.
            let slug = profile.slug
            let identity = try? String(contentsOf: ProfileStore.identityPath(slug), encoding: .utf8)
            let prekey = try? String(contentsOf: ProfileStore.prekeyPath(slug), encoding: .utf8)
            guard let identity, let prekey else {
                os_log("[RVPN] profile files missing — cannot start tunnel", type: .error)
                completion("profile files missing")
                return
            }
            var config = configJSON
            // point the engine at files the extension will write itself
            config = config.replacingOccurrences(
                of: ProfileStore.identityPath(slug).path,
                with: "RVPN_IDENTITY_PLACEHOLDER")
            config = config.replacingOccurrences(
                of: ProfileStore.prekeyPath(slug).path,
                with: "RVPN_PREKEY_PLACEHOLDER")
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = tunnelBundleId
            proto.providerConfiguration = [
                "engineConfig": config,
                "identityKey": identity,
                "prekeyBundle": prekey,
            ]
            proto.serverAddress = profile.serverAddress
            proto.username = profile.name
            manager.protocolConfiguration = proto
            manager.localizedDescription = "R-VPN"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error {
                    os_log("[RVPN] save VPN prefs failed: %{public}@", type: .error, "\(error)")
                    completion("\(error.localizedDescription)")
                    return
                }
                os_log("[RVPN] VPN profile saved, starting tunnel", type: .info)
                // reload so the session exists, then start
                NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                    guard let session = (managers?.first?.connection as? NETunnelProviderSession) else {
                        completion("no tunnel session")
                        return
                    }
                    do {
                        try session.startTunnel()
                        os_log("[RVPN] tunnel started", type: .info)
                        completion(nil)
                    } catch {
                        os_log("[RVPN] startTunnel failed: %{public}@", type: .error, "\(error)")
                        completion("\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    static func disconnect() {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            managers?.forEach { $0.connection.stopVPNTunnel() }
            os_log("[RVPN] tunnel stopped", type: .info)
        }
    }
}
