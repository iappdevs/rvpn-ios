import Foundation
// The C header is exposed via module.modulemap

// MARK: - Rust FFI Bridge

/// Wraps the C API from rvpn_bridge.h in Swift-safe calls.
enum RustVPN {
    // MARK: Lifecycle

    static func initialize() -> Bool {
        rvpn_initialize() == 0
    }

    static func tunCreate(configJSON: String) -> Bool {
        rvpn_tun_create(configJSON) == 0
    }

    static func tunStart() -> Bool {
        rvpn_tun_start() == 0
    }

    static func tunStop() -> Bool {
        rvpn_tun_stop() == 0
    }

    static func tunDestroy() {
        rvpn_tun_destroy()
    }

    // MARK: State

    enum TunState: Int32 {
        case init_ = 0
        case connecting = 1
        case ipAssigned = 2
        case connected = 3
        case error = 4
    }

    static var tunState: TunState {
        TunState(rawValue: rvpn_tun_get_state()) ?? .error
    }

    static var tunnelIP: String? {
        let ptr = rvpn_tun_get_ip()
        defer { rvpn_free_string(ptr) }
        return String(cString: ptr)
    }

    static var gatewayIP: String? {
        let ptr = rvpn_tun_get_gateway_ip()
        defer { rvpn_free_string(ptr) }
        return String(cString: ptr)
    }

    static var mtu: Int {
        rvpn_tun_get_mtu()
    }

    static var serverIdentity: String? {
        let ptr = rvpn_tun_get_server_identity()
        defer { rvpn_free_string(ptr) }
        return String(cString: ptr)
    }

    static var isConnected: Bool {
        tunState == .connected || tunState == .ipAssigned
    }

    static var lastRxTime: UInt64 {
        rvpn_tun_get_last_rx_time()
    }

    // MARK: Packets

    static func writePacket(_ data: Data) -> Bool {
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            rvpn_tun_write_packet(ptr.bindMemory(to: UInt8.self).baseAddress, data.count) == 0
        }
    }

    static func readPacket(into buffer: inout [UInt8]) -> Int? {
        var outLen = 0 as UInt
        let result = buffer.withUnsafeMutableBufferPointer { buf in
            rvpn_tun_read_packet(buf.baseAddress, buf.count, &outLen)
        }
        return result == 0 ? Int(outLen) : nil
    }

    static func waitForPacket(timeoutMs: UInt64) -> Bool {
        rvpn_tun_wait_for_packet(timeoutMs) == 1
    }

    // MARK: Callbacks

    static func setStateCallback(_ callback: @escaping (Int32, String, String) -> Void) {
        let box = Unmanaged.passRetained(CallbackBox(callback))
        rvpn_tun_set_state_callback { state, ip, msg in
            let handler = box.takeUnretainedValue().handler
            let ipStr = ip != nil ? String(cString: ip!) : ""
            let msgStr = msg != nil ? String(cString: msg!) : ""
            handler(state, ipStr, msgStr)
        }
    }

    static func setLogCallback(_ callback: @escaping (Int32, String) -> Void) {
        let box = Unmanaged.passRetained(LogCallbackBox(callback))
        rvpn_set_log_callback { level, msg in
            let handler = box.takeUnretainedValue().handler
            let msgStr = msg != nil ? String(cString: msg!) : ""
            handler(level, msgStr)
        }
    }

    // MARK: Identity

    static func generateIdentity() -> String? {
        let ptr = rvpn_generate_identity()
        defer { rvpn_free_string(ptr) }
        return String(cString: ptr)
    }

    static func validateIdentity(_ content: String) -> Bool {
        rvpn_validate_identity(content) == 0
    }

    // MARK: Network

    static func networkChanged(hasInternet: Bool) {
        rvpn_network_changed(hasInternet ? 1 : 0)
    }

    // MARK: Error

    static var lastError: String? {
        let ptr = rvpn_last_error()
        defer { rvpn_free_string(ptr) }
        return String(cString: ptr)
    }

    // MARK: - Helper classes

    private class CallbackBox {
        let handler: (Int32, String, String) -> Void
        init(_ h: @escaping (Int32, String, String) -> Void) { handler = h }
    }

    private class LogCallbackBox {
        let handler: (Int32, String) -> Void
        init(_ h: @escaping (Int32, String) -> Void) { handler = h }
    }
}
