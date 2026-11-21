import Foundation

/// Snapshot shared by the app and its packet tunnel provider.
struct TunnelStatistics: Codable {
    static let request = Data("rvpn.tunnel.statistics.v1".utf8)

    let serverIP: String?
    let tunnelIP: String?
    let transferredBytes: UInt64
}
