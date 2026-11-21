import Foundation
import os

// MARK: - Raw C ABI (rvpn-mobile ios_tun_ffi.rs)

@_silgen_name("rvpn_initialize")
private func c_rvpn_initialize() -> Int32

@_silgen_name("rvpn_last_error")
private func c_rvpn_last_error() -> UnsafeMutablePointer<CChar>?

@_silgen_name("rvpn_free_string")
private func c_rvpn_free_string(_ string: UnsafeMutablePointer<CChar>?)

@_silgen_name("rvpn_start")
private func c_rvpn_start(_ configJSON: UnsafePointer<CChar>) -> Int32

@_silgen_name("rvpn_stop")
private func c_rvpn_stop() -> Int32

@_silgen_name("rvpn_generate_identity_file")
private func c_rvpn_generate_identity_file(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("rvpn_network_changed")
private func c_rvpn_network_changed(_ hasInternet: Int32) -> Int32

@_silgen_name("rvpn_tun_check_connectivity")
private func c_rvpn_tun_check_connectivity() -> Int32

@_silgen_name("rvpn_tun_get_state")
private func c_rvpn_tun_get_state() -> Int32

@_silgen_name("rvpn_tun_get_ip")
private func c_rvpn_tun_get_ip() -> UnsafeMutablePointer<CChar>?

@_silgen_name("rvpn_tun_get_server_ip")
private func c_rvpn_tun_get_server_ip() -> UnsafeMutablePointer<CChar>?

@_silgen_name("rvpn_tun_get_server_identity")
private func c_rvpn_tun_get_server_identity() -> UnsafeMutablePointer<CChar>?

@_silgen_name("rvpn_tun_get_mtu")
private func c_rvpn_tun_get_mtu() -> Int32

@_silgen_name("rvpn_tun_get_rss_bytes")
private func c_rvpn_tun_get_rss_bytes() -> UInt64

@_silgen_name("rvpn_tun_get_last_rx_time")
private func c_rvpn_tun_get_last_rx_time() -> UInt64

@_silgen_name("rvpn_tun_wait_for_packet")
private func c_rvpn_tun_wait_for_packet(_ timeoutMs: UInt64) -> Int32

@_silgen_name("rvpn_tun_write_packet")
private func c_rvpn_tun_write_packet(_ data: UnsafePointer<UInt8>?, _ len: Int) -> Int32

@_silgen_name("rvpn_tun_read_packet")
private func c_rvpn_tun_read_packet(
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ bufferLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?
) -> Int32

@_silgen_name("rvpn_set_log_callback")
private func c_rvpn_set_log_callback(
    _ callback: (@convention(c) (Int32, UnsafePointer<CChar>?) -> Void)?
)

// MARK: - Swift-friendly wrapper

/// Rust engine log line forwarded to the unified logging system, so
/// `idevicesyslog` (and Console.app) show the engine's own diagnostics.
private func rvpnLogCallback(level: Int32, message: UnsafePointer<CChar>?) {
    let text = message.map { String(cString: $0) } ?? ""
    switch level {
    case 0, 1: os_log("[RVPN-DBG] %{public}@", type: .debug, text)
    case 2: os_log("[RVPN] %{public}@", type: .info, text)
    case 3: os_log("[RVPN] %{public}@", type: .default, text)
    default: os_log("[RVPN] %{public}@", type: .error, text)
    }
}

/// Typed wrapper around the rvpn-mobile C ABI.
enum RustBridge {
    /// Set once the pump thread should stop.
    private static var pumpRunning = false
    /// Engine state codes from `rvpn_tun_get_state()` (TunClientState in ios_tun.rs).
    enum EngineState: Int32 {
        case idle = 0          // Init
        case connecting = 1
        case ipAssigned = 2
        case connected = 3
        case error = 4
    }

    /// Convert an owned Rust string to Swift and free the Rust allocation.
    private static func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { c_rvpn_free_string(ptr) }
        return String(cString: ptr)
    }

    static func takeError() -> String? {
        takeString(c_rvpn_last_error())
    }

    @discardableResult
    static func initialize() -> Int32 {
        c_rvpn_set_log_callback(rvpnLogCallback)
        return c_rvpn_initialize()
    }

    /// Drain the engine's outgoing packets on a background thread.
    ///
    /// The iOS FFI design expects the tunnel provider to pump packets
    /// (`wait_for_packet` → `read_packet` → packetFlow). In the app process
    /// there is no utun device, but draining the channel still keeps the
    /// relay healthy and lets session diagnostics flow while debugging.
    static func startPump() {
        guard !pumpRunning else { return }
        pumpRunning = true
        os_log("[RVPN] packet pump started", type: .info)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while pumpRunning {
                if c_rvpn_tun_wait_for_packet(500) != 1 { continue }
                buffer.withUnsafeMutableBufferPointer { raw in
                    var outLen = 0
                    _ = c_rvpn_tun_read_packet(
                        raw.baseAddress, raw.count, &outLen)
                }
            }
            os_log("[RVPN] packet pump stopped", type: .info)
        }
    }

    static func stopPump() {
        pumpRunning = false
    }

    /// Start the engine with a camelCase MobileConfig JSON payload.
    /// Returns an error message on failure, nil on success.
    static func start(configJSON: String) -> String? {
        var error: String?
        configJSON.withCString { ptr in
            if c_rvpn_start(ptr) != 0 {
                error = takeError() ?? "Unknown engine error"
            }
        }
        return error
    }

    static func stop() {
        _ = c_rvpn_stop()
    }

    /// Generate `identity.key` inside the profile directory when missing.
    static func generateIdentity(at path: String) -> String? {
        var error: String?
        path.withCString { ptr in
            if c_rvpn_generate_identity_file(ptr) != 0 {
                error = takeError() ?? "Failed to generate identity"
            }
        }
        return error
    }

    static func networkChanged(_ hasInternet: Bool) {
        _ = c_rvpn_network_changed(hasInternet ? 1 : 0)
    }

    /// Probe the server; returns an error message on failure, nil when healthy.
    static func checkConnectivity() -> String? {
        c_rvpn_tun_check_connectivity() == 0 ? nil : (takeError() ?? "Connectivity check failed")
    }

    static var engineState: EngineState {
        EngineState(rawValue: c_rvpn_tun_get_state()) ?? .error
    }

    static var tunnelIP: String? { takeString(c_rvpn_tun_get_ip()) }
    static var serverIP: String? { takeString(c_rvpn_tun_get_server_ip()) }
    static var serverIdentity: String? { takeString(c_rvpn_tun_get_server_identity()) }
    static var mtu: Int32 { c_rvpn_tun_get_mtu() }

    /// Bytes transferred through the tunnel since connect.
    static var transferredBytes: UInt64 { c_rvpn_tun_get_rss_bytes() }

    /// Seconds since the last received packet (0 = no data yet).
    static var secondsSinceLastPacket: UInt64 { c_rvpn_tun_get_last_rx_time() }

    // MARK: - Raw packet bridge (tunnel provider)

    /// Feed one packet from the device into the engine.
    static func writePacket(_ raw: UnsafeRawBufferPointer) -> Int32 {
        guard let base = raw.baseAddress else { return -1 }
        return c_rvpn_tun_write_packet(base.assumingMemoryBound(to: UInt8.self), raw.count)
    }

    /// Wait until the engine has at least one packet (1) or timeout (0).
    static func waitForPacket(timeoutMs: UInt64) -> Int32 {
        c_rvpn_tun_wait_for_packet(timeoutMs)
    }

    /// Drain one engine packet into `buffer`; returns its length (0 = none).
    static func readPacket(into buffer: inout [UInt8]) -> Int {
        var outLen = 0
        let rc = buffer.withUnsafeMutableBufferPointer { raw in
            c_rvpn_tun_read_packet(raw.baseAddress, raw.count, &outLen)
        }
        return rc == 0 ? outLen : 0
    }
}
