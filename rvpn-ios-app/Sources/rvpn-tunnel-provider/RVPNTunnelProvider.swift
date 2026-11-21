import Foundation
import NetworkExtension
import os

/// Packet tunnel provider — the process iOS runs while the VPN is up.
///
/// Bridges the system utun device to the Rust rVPN engine:
/// packetFlow reads -> rvpn_tun_write_packet, engine -> packetFlow writes.
class RVPNTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "org.rvpn.ios.tunnel", category: "engine")
    private var pumpThread: Thread?

    override func startTunnel(
        options: [String: NSObject]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("[RVPN-TUNNEL] startTunnel called", type: .info)
        guard let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration,
            var config = providerConfig["engineConfig"] as? String,
            let identity = providerConfig["identityKey"] as? String,
            let prekey = providerConfig["prekeyBundle"] as? String
        else {
            os_log("[RVPN-TUNNEL] incomplete providerConfiguration", type: .error)
            completionHandler(NSError(domain: "org.rvpn.ios.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing engineConfig"]))
            return
        }
        // Materialise identity/prekey inside THIS process's sandbox.
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let identityURL = dir.appendingPathComponent("identity.key")
        let prekeyURL = dir.appendingPathComponent("prekey-bundle.json")
        do {
            try identity.write(to: identityURL, atomically: true, encoding: .utf8)
            try prekey.write(to: prekeyURL, atomically: true, encoding: .utf8)
        } catch {
            os_log("[RVPN-TUNNEL] cannot write key files: %{public}@", type: .error, "\(error)")
            completionHandler(NSError(domain: "org.rvpn.ios.tunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
            return
        }
        config = config.replacingOccurrences(of: "RVPN_IDENTITY_PLACEHOLDER", with: identityURL.path)
        config = config.replacingOccurrences(of: "RVPN_PREKEY_PLACEHOLDER", with: prekeyURL.path)
        os_log("[RVPN-TUNNEL] key files staged in extension sandbox", type: .info)

        // 1) boot the engine
        if let error = RustBridge.start(configJSON: config) {
            os_log("[RVPN-TUNNEL] engine start failed: %{public}@", type: .error, error)
            completionHandler(NSError(domain: "org.rvpn.ios.tunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: error]))
            return
        }
        os_log("[RVPN-TUNNEL] engine started", type: .info)

        // 2) configure the virtual interface
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.200.0.4"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: serverHostIP(), subnetMask: "255.255.255.255"),
        ]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.mtu = 1420

        setTunnelNetworkSettings(settings) { error in
            if let error {
                os_log("[RVPN-TUNNEL] network settings error: %{public}@", type: .error, "\(error)")
                completionHandler(error)
                return
            }
            os_log("[RVPN-TUNNEL] tunnel settings applied", type: .info)
            // 3) pump packets both ways until the tunnel stops
            self.startPump()
            completionHandler(nil)
        }
    }

    /// Best-effort server IP for the bypass route; 0.0.0.0 keeps default routing.
    private func serverHostIP() -> String {
        RustBridge.serverIP ?? "0.0.0.0"
    }

    private func startPump() {
        readLoop()
        pumpThread = Thread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                if RustBridge.waitForPacket(timeoutMs: 500) == 1 {
                    let count = RustBridge.readPacket(into: &buffer)
                    if count > 0 {
                        let data = Data(buffer[0..<count])
                        self.packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
                    }
                }
            }
        }
        pumpThread?.name = "rvpn-pump"
        pumpThread?.start()
        os_log("[RVPN-TUNNEL] pump loops running", type: .info)
    }

    /// device -> engine, re-arming after every batch.
    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            for packet in packets {
                packet.withUnsafeBytes { raw in
                    _ = RustBridge.writePacket(raw)
                }
            }
            self?.readLoop()
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("[RVPN-TUNNEL] stopTunnel reason=%ld", type: .info, reason.rawValue)
        RustBridge.stop()
        completionHandler()
    }
}

