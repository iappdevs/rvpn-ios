import Foundation
import NetworkExtension
import os
import SwiftUI

/// App-wide observable state: profiles, active connection, live stats.
@MainActor
final class AppState: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .disconnecting: return "Disconnecting…"
            case .failed: return "Failed"
            }
        }
    }

    @Published var profiles: [Profile] = [] {
        didSet { ProfileStore.save(profiles) }
    }
    @Published var activeProfileSlug: String? {
        didSet { UserDefaults.standard.set(activeProfileSlug, forKey: "activeProfileSlug") }
    }
    @Published var connectionState: ConnectionState = .disconnected
    @Published var tunnelIP: String?
    @Published var serverIP: String?
    @Published var transferredBytes: UInt64?
    @Published var lastError: String?

    private var statsTimer: Timer?
    private var statisticsRequest: (id: UUID, deadline: DispatchTime)?
    private var vpnManager: NETunnelProviderManager?
    private var vpnSetup: Task<Void, Never>?
    private var systemVPNObserver: NSObjectProtocol?
    /// Keeps sockets alive ~30 s when the app moves to the background.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var activeProfile: Profile? {
        profiles.first { $0.slug == activeProfileSlug }
    }

    init() {
        profiles = ProfileStore.load()
        activeProfileSlug = UserDefaults.standard.string(forKey: "activeProfileSlug")
        setenv("RVPN_LOG_LEVEL", "info", 1)
        RustBridge.initialize()
        os_log("[RVPN] app init (engine runtime up, RVPN_LOG_LEVEL=info)", type: .info)
        startStatsPolling()
        if VPNManager.extensionAvailable {
            observeSystemVPN()
        } else {
            observeLifecycle()
        }
    }

    deinit {
        statsTimer?.invalidate()
        if let systemVPNObserver {
            NotificationCenter.default.removeObserver(systemVPNObserver)
        }
    }

    private func observeSystemVPN() {
        systemVPNObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                guard let self, self.vpnManager?.connection === connection else { return }
                self.refreshSystemVPN(connection)
            }
        }
        Task {
            let savedManager = try? await VPNManager.existingManager()
            guard vpnSetup == nil, vpnManager == nil, let savedManager else { return }
            vpnManager = savedManager
            refreshSystemVPN(savedManager.connection)
        }
    }

    /// Mark every interesting transition in the unified log so a device
    /// syslog captures the full story while debugging.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            os_log("[RVPN] app entered background", type: .info)
            guard let self, self.connectionState == .connected || self.connectionState == .connecting else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "rvpn-engine") {
                os_log("[RVPN] background time expired — engine will suspend", type: .error)
                self.endBackgroundTask()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            os_log("[RVPN] app entered foreground", type: .info)
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Connection

    func connect(profile: Profile) {
        guard vpnSetup == nil, connectionState != .connected,
              connectionState != .connecting, connectionState != .disconnecting else { return }
        activeProfileSlug = profile.slug
        connectionState = .connecting
        lastError = nil

        guard VPNManager.extensionAvailable else {
            startInAppEngine(profile: profile)
            return
        }
        vpnSetup = Task {
            defer { vpnSetup = nil }
            do {
                let manager = try await VPNManager.prepare(profile: profile)
                try Task.checkCancellation()
                vpnManager = manager
                guard let session = manager.connection as? NETunnelProviderSession else {
                    let message = "The system VPN session is unavailable."
                    lastError = message
                    connectionState = .failed(message)
                    return
                }
                guard session.status == .disconnected || session.status == .invalid else {
                    refreshSystemVPN(session)
                    return
                }
                try session.startTunnel()
                os_log("[RVPN] system tunnel start requested", type: .info)
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshSystemVPN(_ connection: NEVPNConnection) {
        let status = connection.status
        if status != .connected {
            clearStatistics()
        }
        switch status {
        case .connected:
            lastError = nil
            connectionState = .connected
            requestTunnelStatistics()
        case .connecting, .reasserting:
            connectionState = .connecting
        case .disconnecting:
            connectionState = .disconnecting
        case .disconnected, .invalid:
            if case .failed = connectionState { return }
            let wasConnecting = connectionState == .connecting
            let shouldReadError = wasConnecting || connectionState == .connected
            connectionState = .disconnected
            guard shouldReadError else { return }
            connection.fetchLastDisconnectError { [weak self] error in
                let message = error?.localizedDescription ?? (wasConnecting ? "The system VPN could not connect." : nil)
                guard let message else { return }
                Task { @MainActor in
                    guard let self, self.vpnSetup == nil, self.vpnManager?.connection === connection,
                          self.connectionState == .disconnected else { return }
                    self.lastError = message
                    self.connectionState = .failed(message)
                }
            }
        @unknown default:
            connectionState = .disconnected
        }
    }

    /// Direct in-process engine session (no system VPN profile).
    private func startInAppEngine(profile: Profile) {
        let configJSON = ProfileStore.engineConfig(for: profile)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let error = RustBridge.start(configJSON: configJSON) {
                os_log("[RVPN] engine start failed: %{public}@", type: .error, error)
                Task { @MainActor in
                    self.connectionState = .failed(error)
                    self.lastError = error
                }
                return
            }
            os_log("[RVPN] engine started, pumping packets", type: .info)
            RustBridge.startPump()
            Task { @MainActor in self.refreshState() }
        }
    }

    func disconnect() {
        os_log("[RVPN] disconnect requested", type: .info)
        clearStatistics()
        if VPNManager.extensionAvailable {
            vpnSetup?.cancel()
            guard let connection = vpnManager?.connection else {
                connectionState = .disconnected
                return
            }
            connectionState = connection.status == .disconnected || connection.status == .invalid
                ? .disconnected : .disconnecting
            connection.stopVPNTunnel()
            return
        }
        RustBridge.stopPump()
        RustBridge.stop()
        connectionState = .disconnected
    }

    /// Probe the active profile's server without establishing a session.
    func testConnectivity(profile: Profile, completion: @escaping (String?) -> Void) {
        let configJSON = ProfileStore.engineConfig(for: profile)
        DispatchQueue.global(qos: .userInitiated).async {
            // The engine requires a session for the probe; a start+stop cycle
            // performs the handshake and reports the failure reason.
            if let error = RustBridge.start(configJSON: configJSON) {
                completion(error)
            } else {
                RustBridge.stop()
                completion(nil)
            }
        }
    }

    // MARK: - Profile management

    func addProfile(_ profile: Profile) {
        profiles.append(profile)
        activeProfileSlug = profile.slug
    }

    func deleteProfile(at offsets: IndexSet) {
        for index in offsets {
            if profiles[index].slug == activeProfileSlug, connectionState != .disconnected {
                disconnect()
            }
            ProfileStore.delete(profiles[index])
        }
        profiles.remove(atOffsets: offsets)
        if let slug = activeProfileSlug, !profiles.contains(where: { $0.slug == slug }) {
            activeProfileSlug = profiles.first?.slug
        }
    }

    // MARK: - Stats

    private func startStatsPolling() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if VPNManager.extensionAvailable {
                    self?.requestTunnelStatistics()
                } else {
                    self?.refreshState()
                }
            }
        }
    }

    private func requestTunnelStatistics() {
        guard connectionState == .connected,
              let session = vpnManager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return }
        let now = DispatchTime.now()
        if let statisticsRequest, statisticsRequest.deadline > now { return }

        let id = UUID()
        statisticsRequest = (id, now + .seconds(3))
        do {
            try session.sendProviderMessage(TunnelStatistics.request) { [weak self, weak session] data in
                Task { @MainActor in
                    guard let self, self.statisticsRequest?.id == id else { return }
                    self.statisticsRequest = nil
                    guard let session, self.connectionState == .connected, session.status == .connected,
                          self.vpnManager?.connection === session,
                          let data, let statistics = try? JSONDecoder().decode(TunnelStatistics.self, from: data)
                    else { return }

                    let configuration = self.vpnManager?.protocolConfiguration as? NETunnelProviderProtocol
                    let configuredHost = configuration?.serverAddress.flatMap { URL(string: $0)?.host }
                    self.serverIP = statistics.serverIP ?? configuredHost
                    self.tunnelIP = statistics.tunnelIP
                    self.transferredBytes = statistics.transferredBytes
                }
            }
        } catch {
            statisticsRequest = nil
        }
    }

    private func clearStatistics() {
        statisticsRequest = nil
        tunnelIP = nil
        serverIP = nil
        transferredBytes = nil
    }

    /// Poll cycle counter so periodic state lines stay identifiable.
    private static var pollCount = 0

    private func refreshState() {
        let engine = RustBridge.engineState
        let ip = RustBridge.tunnelIP
        AppState.pollCount &+= 1
        let engineLabel = String(describing: engine)

        // Derive the UI state from the engine state first, then log real changes.
        let derived: ConnectionState
        switch engine {
        case .connected, .ipAssigned:
            derived = .connected
        case .connecting:
            derived = connectionState == .disconnected ? .connecting : connectionState
        default:
            derived = (connectionState == .connected || connectionState == .connecting)
                ? .disconnected : connectionState
        }
        if derived != connectionState {
            os_log("[RVPN] ui-state %{public}@ -> %{public}@ (engine=%{public}@ ip=%{public}@)",
                   type: .info, connectionState.label, derived.label, engineLabel, ip ?? "-")
            connectionState = derived
        }
        if AppState.pollCount % 10 == 0 {
            os_log("[RVPN] tick engine=%{public}@ ip=%{public}@",
                   type: .debug, engineLabel, ip ?? "-")
        }
        tunnelIP = ip
        serverIP = RustBridge.serverIP
    }
}
