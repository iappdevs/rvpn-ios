import Foundation

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

@_silgen_name("rvpn_generate_identity")
private func c_rvpn_generate_identity(_ path: UnsafePointer<CChar>) -> Int32

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

// MARK: - Swift-friendly wrapper

/// Typed wrapper around the rvpn-mobile C ABI.
enum RustBridge {
    /// Engine state codes from `rvpn_tun_get_state()`.
    enum EngineState: Int32 {
        case idle = 0
        case connecting = 1
        case connected = 2
        case disconnected = 3
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
        c_rvpn_initialize()
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
        c_rvpn_stop()
    }

    /// Generate `identity.key` inside the profile directory when missing.
    static func generateIdentity(at path: String) -> String? {
        var error: String?
        path.withCString { ptr in
            if c_rvpn_generate_identity(ptr) != 0 {
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
}
