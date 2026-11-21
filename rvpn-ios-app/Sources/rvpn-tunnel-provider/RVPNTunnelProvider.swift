import Darwin
import Foundation
import NetworkExtension
import os

/// Packet tunnel provider — the process iOS runs while the VPN is up.
///
/// Bridges the system utun device to the Rust rVPN engine:
/// packetFlow reads -> rvpn_tun_write_packet, engine -> packetFlow writes.
class RVPNTunnelProvider: NEPacketTunnelProvider {
    private let tunnelQueue = DispatchQueue(label: "org.rvpn.ios.tunnel")
    private let pumpGroup = DispatchGroup()
    private let trafficLock = NSLock()
    private var uplinkQueuedBytes: UInt64 = 0
    private var downlinkDeliveredBytes: UInt64 = 0
    private var pumpThread: Thread?
    private var tunnelID: UUID?
    private var startCompletion: ((Error?) -> Void)?

    override func startTunnel(
        options: [String: NSObject]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        tunnelQueue.async {
            guard self.tunnelID == nil else {
                completionHandler(self.tunnelError("Tunnel is already starting or active"))
                return
            }
            let id = UUID()
            self.tunnelID = id
            self.startCompletion = completionHandler
            // The previous pump has finished before this queue accepts a new start.
            self.uplinkQueuedBytes = 0
            self.downlinkDeliveredBytes = 0
            self.startEngine(id: id)
        }
    }

    private func startEngine(id: UUID) {
        os_log("[RVPN-TUNNEL] startTunnel called", type: .info)
        guard let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration,
            let configJSON = providerConfig["engineConfig"] as? String,
            let identity = providerConfig["identityKey"] as? String,
            let prekey = providerConfig["prekeyBundle"] as? String,
            !identity.isEmpty, !prekey.isEmpty
        else {
            finishStart(tunnelError("VPN profile is missing its configuration or key files"))
            return
        }
        guard var config = (try? JSONSerialization.jsonObject(with: Data(configJSON.utf8))) as? [String: Any] else {
            finishStart(tunnelError("Invalid VPN engine configuration"))
            return
        }

        let files = FileManager.default
        do {
            let dir = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let identityURL = dir.appendingPathComponent("identity.key")
            let prekeyURL = dir.appendingPathComponent("prekey-bundle.json")
            try identity.write(to: identityURL, atomically: true, encoding: .utf8)
            try prekey.write(to: prekeyURL, atomically: true, encoding: .utf8)

            // Overwrite the parsed fields, including paths kept by older saved profiles.
            config["identityKeyPath"] = identityURL.path
            config["prekeyBundlePath"] = prekeyURL.path
        } catch {
            finishStart(tunnelError("Could not stage VPN key files"))
            return
        }
        guard let configData = try? JSONSerialization.data(withJSONObject: config) else {
            finishStart(tunnelError("Could not encode VPN engine configuration"))
            return
        }

        setenv("RVPN_LOG_LEVEL", "info", 1)
        guard RustBridge.initialize() == 0 else {
            finishStart(tunnelError(RustBridge.takeError() ?? "Could not initialize the VPN engine"))
            return
        }
        if let error = RustBridge.start(configJSON: String(decoding: configData, as: UTF8.self)) {
            finishStart(tunnelError(error))
            return
        }
        os_log("[RVPN-TUNNEL] engine started; waiting for the server", type: .info)
        waitForAssignment(id: id, deadline: .now() + .seconds(20), dnsServers: config["dnsServers"] as? [String])
    }

    private func waitForAssignment(id: UUID, deadline: DispatchTime, dnsServers: [String]?) {
        guard tunnelID == id else { return }
        if RustBridge.engineState == .connected, let ip = RustBridge.tunnelIP {
            let mtu = RustBridge.mtu
            if mtu > 0 {
                applyNetworkSettings(id: id, address: ip, mtu: mtu, dnsServers: dnsServers)
                return
            }
        }
        guard DispatchTime.now() < deadline else {
            finishStart(tunnelError("VPN server did not assign a tunnel address within 20 seconds"))
            return
        }
        tunnelQueue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.waitForAssignment(id: id, deadline: deadline, dnsServers: dnsServers)
        }
    }

    private func applyNetworkSettings(id: UUID, address: String, mtu: Int32, dnsServers: [String]?) {
        let serverIP = RustBridge.serverIP
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverIP ?? "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        var ipv4Address = in_addr()
        if let serverIP, inet_pton(AF_INET, serverIP, &ipv4Address) == 1 {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255")]
        }
        settings.ipv4Settings = ipv4
        let resolvers = dnsServers ?? []
        settings.dnsSettings = NEDNSSettings(servers: resolvers.isEmpty ? ["1.1.1.1", "8.8.8.8"] : resolvers)
        settings.mtu = NSNumber(value: mtu)

        setTunnelNetworkSettings(settings) { error in
            self.tunnelQueue.async {
                guard self.tunnelID == id else { return }
                if let error {
                    self.finishStart(error)
                    return
                }
                self.startPump(id: id)
                os_log("[RVPN-TUNNEL] tunnel settings applied and packet pump running", type: .info)
                self.finishStart(nil)
            }
        }
    }

    private func finishStart(_ error: Error?) {
        let completion = startCompletion
        startCompletion = nil
        if let error {
            os_log("[RVPN-TUNNEL] startup failed: %{public}@", type: .error, error.localizedDescription)
            stopEngine()
        }
        completion?(error)
    }

    private func tunnelError(_ message: String) -> NSError {
        NSError(domain: "org.rvpn.ios.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
        guard let completionHandler else { return }
        tunnelQueue.async {
            guard messageData == TunnelStatistics.request, self.tunnelID != nil, self.startCompletion == nil else {
                completionHandler(nil)
                return
            }
            self.trafficLock.lock()
            let bytes = self.uplinkQueuedBytes &+ self.downlinkDeliveredBytes
            self.trafficLock.unlock()
            let statistics = TunnelStatistics(
                serverIP: RustBridge.serverIP,
                tunnelIP: RustBridge.tunnelIP,
                transferredBytes: bytes
            )
            completionHandler(try? JSONEncoder().encode(statistics))
        }
    }

    private func startPump(id: UUID) {
        readLoop(id: id)
        pumpGroup.enter()
        let thread = Thread {
            defer { self.pumpGroup.leave() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !Thread.current.isCancelled {
                guard RustBridge.waitForPacket(timeoutMs: 250) == 1 else { continue }
                // Rust coalesces wakeups, so one signal may cover several batches.
                while !Thread.current.isCancelled {
                    let count = RustBridge.readPacketBatch(into: &buffer)
                    guard count > 0 else { break }
                    self.writeDownlinkBatch(buffer.prefix(count))
                }
            }
        }
        pumpThread = thread
        thread.name = "rvpn-pump"
        thread.start()
    }

    /// Rust puts a two-byte little-endian length in front of each IP packet.
    private func writeDownlinkBatch(_ batch: ArraySlice<UInt8>) {
        var remaining = batch
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        var bytes: UInt64 = 0
        while !remaining.isEmpty {
            guard remaining.count >= 2 else { return }
            let header = remaining.startIndex
            let length = Int(remaining[header]) | (Int(remaining[header + 1]) << 8)
            guard length > 0, length <= remaining.count - 2 else { return }
            let packet = remaining.dropFirst(2).prefix(length)
            remaining = remaining.dropFirst(2 + length)

            let family: Int32
            switch packet[packet.startIndex] >> 4 {
            case 4: family = AF_INET
            case 6: family = AF_INET6
            default: continue
            }
            packets.append(Data(packet))
            protocols.append(NSNumber(value: family))
            bytes += UInt64(length)
        }
        guard !packets.isEmpty, packetFlow.writePackets(packets, withProtocols: protocols) else { return }
        trafficLock.lock()
        downlinkDeliveredBytes &+= bytes
        trafficLock.unlock()
    }

    /// device -> engine, re-arming after every batch.
    private func readLoop(id: UUID) {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.tunnelQueue.async {
                guard self.tunnelID == id else { return }
                var forwardedBytes: UInt64 = 0
                for packet in packets {
                    if packet.withUnsafeBytes(RustBridge.writePacket) == 0 {
                        forwardedBytes += UInt64(packet.count)
                    }
                }
                // The uplink and statistics requests share tunnelQueue.
                self.uplinkQueuedBytes &+= forwardedBytes
                self.readLoop(id: id)
            }
        }
    }

    private func stopEngine() {
        tunnelID = nil
        pumpThread?.cancel()
        pumpGroup.wait()
        if pumpThread != nil {
            os_log("[RVPN-TUNNEL] packet pump stopped: uplink queued=%llu bytes, downlink delivered=%llu bytes",
                   type: .info, uplinkQueuedBytes, downlinkDeliveredBytes)
        }
        pumpThread = nil
        RustBridge.stop()
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        tunnelQueue.async {
            os_log("[RVPN-TUNNEL] stopTunnel reason=%ld", type: .info, reason.rawValue)
            if self.startCompletion != nil {
                self.finishStart(self.tunnelError("VPN startup cancelled"))
            } else {
                self.stopEngine()
            }
            completionHandler()
        }
    }
}

