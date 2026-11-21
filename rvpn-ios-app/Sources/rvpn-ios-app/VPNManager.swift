import Foundation
import NetworkExtension
import os

/// Creates and drives the system VPN profile (Settings → VPN).
enum VPNManager {
    private static let tunnelBundleId = "org.rvpn.ios.tunnel"

    /// Load (or create) our tunnel configuration, then bring the tunnel up.
    static func connect(profile: Profile, completion: @escaping (String?) -> Void) {
        let configJSON = ProfileStore.engineConfig(for: profile)
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                os_log("[RVPN] load VPN prefs failed: %{public}@", type: .error, "\(error)")
                completion("\(error.localizedDescription)")
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = tunnelBundleId
            proto.providerConfiguration = ["engineConfig": configJSON]
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
