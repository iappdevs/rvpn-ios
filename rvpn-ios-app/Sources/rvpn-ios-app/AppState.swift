import Foundation
import os
import SwiftUI

/// App-wide observable state: profiles, active connection, live stats.
@MainActor
final class AppState: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
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
    @Published var transferredBytes: UInt64 = 0
    @Published var lastError: String?

    private var statsTimer: Timer?
    /// Keeps sockets alive ~30 s when the app moves to the background.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var activeProfile: Profile? {
        profiles.first { $0.slug == activeProfileSlug }
    }

    init() {
        profiles = ProfileStore.load()
        activeProfileSlug = UserDefaults.standard.string(forKey: "activeProfileSlug")
        RustBridge.initialize()
        startStatsPolling()
        observeLifecycle()
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
        if case .connected = connectionState { return }
        if case .connecting = connectionState { return }
        activeProfileSlug = profile.slug
        connectionState = .connecting
        lastError = nil

        // Provisioning + engine start run off the main thread; the engine
        // logs and connects on its own tokio runtime.
        os_log("[RVPN] connect requested for %{public}@ (%{public}@)", type: .info, profile.name, profile.serverAddress)
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
        RustBridge.stopPump()
        RustBridge.stop()
        connectionState = .disconnected
        tunnelIP = nil
        serverIP = nil
        transferredBytes = 0
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
            Task { @MainActor in self?.refreshState() }
        }
    }

    private func refreshState() {
        switch RustBridge.engineState {
        case .connected:
            if connectionState != .connected { connectionState = .connected }
        case .connecting:
            if connectionState == .disconnected { connectionState = .connecting }
        default:
            if connectionState == .connected || connectionState == .connecting {
                connectionState = .disconnected
            }
        }
        tunnelIP = RustBridge.tunnelIP
        serverIP = RustBridge.serverIP
        transferredBytes = RustBridge.transferredBytes
    }
}
