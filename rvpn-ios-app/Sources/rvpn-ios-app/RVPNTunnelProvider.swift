import Foundation
import NetworkExtension
import os

/// Packet Tunnel Provider — the iOS VPN extension that routes all device
/// traffic through the rVPN engine. The Rust engine (compiled as a static
/// library) is linked directly into this extension.
class RVPNTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "org.rvpn.tunnel", category: "provider")
    private var packetReadTimer: DispatchSourceTimer?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("Starting R-VPN tunnel")

        // 1. Extract the engine config from the provider settings
        guard let configJSON = self.protocolConfiguration.providerConfiguration?["engineConfig"] as? String else {
            completionHandler(VPNError.configurationMissing)
            return
        }

        // 2. Set up the tunnel network settings
        //    (the virtual IP/gateway are assigned by the server, but we need
        //     to set the interface first — the engine will tell us the IP
        //     via the state callback and we update settings then)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1420

        // IPv4 settings — placeholder until the engine assigns the real IP
        let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // DNS — our loopback DoH proxy
        let dns = NEDNSSettings(servers: ["1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        // 3. Apply settings, then initialize the Rust engine
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard error == nil else {
                completionHandler(error)
                return
            }

            // 4. Initialize the Rust engine
            RustVPN.initialize()

            // 5. Set up the state callback
            RustVPN.setStateCallback { [weak self] state, ip, msg in
                guard let self = self else { return }
                self.log.info("Engine state: \(state), IP: \(ip)")

                if state == 3 { // Connected
                    // Update tunnel settings with the real assigned IP
                    self.updateTunnelSettings(ip: ip)
                    completionHandler(nil)

                    // Start the packet pump
                    self.startPacketPump()
                } else if state == 4 { // Error
                    self.log.error("Engine error: \(msg)")
                    completionHandler(VPNError.engineError(msg))
                }
            }

            // 6. Create and start the engine
            guard RustVPN.tunCreate(configJSON: configJSON) else {
                let err = RustVPN.lastError ?? "Unknown engine error"
                self.log.error("Failed to create engine: \(err)")
                completionHandler(VPNError.engineError(err))
                return
            }

            guard RustVPN.tunStart() else {
                let err = RustVPN.lastError ?? "Failed to start engine"
                self.log.error("Failed to start engine: \(err)")
                completionHandler(VPNError.engineError(err))
                return
            }

            self.log.info("Engine started, waiting for connection…")
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("Stopping R-VPN tunnel (reason: \(reason.rawValue))")

        packetReadTimer?.cancel()
        packetReadTimer = nil

        RustVPN.tunStop()
        RustVPN.tunDestroy()

        completionHandler()
    }

    // MARK: - Packet Pump

    /// Read packets from the TUN interface and feed them to the Rust engine,
    /// and vice versa. On iOS, this uses the packetFlow read/write API
    /// instead of a file descriptor.
    private func startPacketPump() {
        let queue = DispatchQueue(label: "org.rvpn.packet-pump", qos: .userInitiated)

        // Uplink: packetFlow → Rust engine
        packetFlow.readPacketObjects { [weak self] packets in
            guard let self = self else { return }

            for packet in packets {
                let data = packet.data
                data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    _ = RustVPN.writePacket(Data(ptr.bindMemory(to: UInt8.self)))
                }
            }

            // Continue reading
            self.packetFlow.readPacketObjects { packets in
                for packet in packets {
                    _ = RustVPN.writePacket(packet.data)
                }
                // Loop continues — readPacketObjects calls back when new
                // packets are available
                self.startPacketPump()
            }
        }

        // Downlink: Rust engine → packetFlow
        // The engine signals new packets via wait_for_packet; we poll it
        // on a timer and write batches to the TUN interface.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            if RustVPN.waitForPacket(timeoutMs: 0) {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while let len = RustVPN.readPacket(into: &buffer) {
                    if len > 0 {
                        let packet = NEPacket(
                            data: Data(buffer[0..<len]),
                            protocolNumber: AF_INET
                        )
                        self.packetFlow.writePacketObjects([packet])
                    }
                }
            }
        }
        timer.resume()
        packetReadTimer = timer
    }

    private func updateTunnelSettings(ip: String) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = UInt16(RustVPN.mtu)

        let ipv4 = NEIPv4Settings(addresses: [ip], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]

        // Bypass the VPN server itself
        if let serverIP = RustVPN.serverIdentity {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255")]
        }

        settings.ipv4Settings = ipv4

        // DNS through the tunnel
        let dns = NEDNSSettings(servers: ["1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                self.log.error("Failed to update tunnel settings: \(error)")
            } else {
                self.log.info("Tunnel settings updated with IP: \(ip)")
            }
        }
    }

    // MARK: - Errors

    enum VPNError: LocalizedError {
        case configurationMissing
        case engineError(String)

        var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "Engine configuration is missing"
            case .engineError(let msg):
                return "Engine error: \(msg)"
            }
        }
    }
}
