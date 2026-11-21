import Foundation

// MARK: - C function declarations (no module needed)

// We declare the C functions directly with @_silgen_name instead of
// importing a module. This avoids SwiftPM's C target complexity while
// the linker resolves the symbols from librvpn_mobile.a.

@_silgen_name("rvpn_initialize")
func c_rvpn_initialize() -> Int32
@_silgen_name("rvpn_tun_create")
func c_rvpn_tun_create(_ config: UnsafePointer<CChar>) -> Int32
@_silgen_name("rvpn_tun_start")
func c_rvpn_tun_start() -> Int32
@_silgen_name("rvpn_tun_stop")
func c_rvpn_tun_stop() -> Int32
@_silgen_name("rvpn_tun_destroy")
func c_rvpn_tun_destroy()
@_silgen_name("rvpn_tun_get_state")
func c_rvpn_tun_get_state() -> Int32
@_silgen_name("rvpn_tun_get_ip")
func c_rvpn_tun_get_ip() -> UnsafeMutablePointer<CChar>?
@_silgen_name("rvpn_tun_get_gateway_ip")
func c_rvpn_tun_get_gateway_ip() -> UnsafeMutablePointer<CChar>?
@_silgen_name("rvpn_tun_get_mtu")
func c_rvpn_tun_get_mtu() -> Int32
@_silgen_name("rvpn_tun_get_server_ip")
func c_rvpn_tun_get_server_ip() -> UnsafeMutablePointer<CChar>?
@_silgen_name("rvpn_tun_get_server_identity")
func c_rvpn_tun_get_server_identity() -> UnsafeMutablePointer<CChar>?
@_silgen_name("rvpn_tun_get_last_rx_time")
func c_rvpn_tun_get_last_rx_time() -> UInt64
@_silgen_name("rvpn_tun_write_packet")
func c_rvpn_tun_write_packet(_ data: UnsafePointer<UInt8>, _ len: UInt) -> Int32
@_silgen_name("rvpn_tun_read_packet")
func c_rvpn_tun_read_packet(_ buf: UnsafeMutablePointer<UInt8>, _ bufLen: UInt, _ outLen: UnsafeMutablePointer<UInt>) -> Int32
@_silgen_name("rvpn_tun_wait_for_packet")
func c_rvpn_tun_wait_for_packet(_ timeoutMs: UInt64) -> Int32
@_silgen_name("rvpn_tun_set_state_callback")
func c_rvpn_tun_set_state_callback(_ cb: @escaping @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void)
@_silgen_name("rvpn_generate_identity")
func c_rvpn_generate_identity() -> UnsafeMutablePointer<CChar>?
@_silgen_name("rvpn_validate_identity")
func c_rvpn_validate_identity(_ content: UnsafePointer<CChar>) -> Int32
@_silgen_name("rvpn_network_changed")
func c_rvpn_network_changed(_ hasInternet: Int32) -> Int32
@_silgen_name("rvpn_last_error")
func c_rvpn_last_error() -> UnsafeMutablePointer<CChar>?
@_silgen_name("rvpn_free_string")
func c_rvpn_free_string(_ str: UnsafeMutablePointer<CChar>?)

// MARK: - Swift-safe wrapper

enum RustVPN {
    static func initialize() -> Bool { c_rvpn_initialize() == 0 }
    static func tunCreate(configJSON: String) -> Bool {
        c_rvpn_tun_create(configJSON) == 0
    }
    static func tunStart() -> Bool { c_rvpn_tun_start() == 0 }
    static func tunStop() -> Bool { c_rvpn_tun_stop() == 0 }
    static func tunDestroy() { c_rvpn_tun_destroy() }
    static var tunState: Int32 { c_rvpn_tun_get_state() }
    static var isConnected: Bool { tunState == 3 || tunState == 2 }
    static var tunnelIP: String? {
        guard let ptr = c_rvpn_tun_get_ip() else { return nil }
        defer { c_rvpn_free_string(ptr) }
        return String(cString: ptr)
    }
    static var gatewayIP: String? {
        guard let ptr = c_rvpn_tun_get_gateway_ip() else { return nil }
        defer { c_rvpn_free_string(ptr) }
        return String(cString: ptr)
    }
    static var mtu: Int { Int(c_rvpn_tun_get_mtu()) }
    static var serverIdentity: String? {
        guard let ptr = c_rvpn_tun_get_server_identity() else { return nil }
        defer { c_rvpn_free_string(ptr) }
        return String(cString: ptr)
    }
    static func generateIdentity() -> String? {
        guard let ptr = c_rvpn_generate_identity() else { return nil }
        defer { c_rvpn_free_string(ptr) }
        return String(cString: ptr)
    }
    static var lastError: String? {
        guard let ptr = c_rvpn_last_error() else { return nil }
        defer { c_rvpn_free_string(ptr) }
        return String(cString: ptr)
    }
    static func setStateCallback(_ cb: @escaping @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void) {
        c_rvpn_tun_set_state_callback(cb)
    }
}

