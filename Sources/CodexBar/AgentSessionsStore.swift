import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class AgentSessionsStore {
    typealias LocalScan = @Sendable (_ includeFileOnlySessions: Bool) async -> [AgentSession]

    private let settings: SettingsStore
    private let localScan: LocalScan
    @ObservationIgnored private var localRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var localRefreshInFlight = false
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var localSessions: [AgentSession] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var latestLocalActivityAt: Date?

    init(
        settings: SettingsStore,
        localScanner: LocalAgentSessionScanner = LocalAgentSessionScanner())
    {
        self.settings = settings
        self.localScan = { includeFileOnlySessions in
            await localScanner.scan(includeFileOnlySessions: includeFileOnlySessions)
        }
    }

    init(
        settings: SettingsStore,
        localScan: @escaping LocalScan)
    {
        self.settings = settings
        self.localScan = localScan
    }

    var totalCount: Int {
        self.localSessions.count
    }

    /// Adaptive refresh uses local metadata only after explicit consent.
    var localMonitoringEnabled: Bool {
        self.settings.agentSessionsEnabled || self.settings.adaptiveActivityScanningEnabled
    }

    nonisolated static func latestActivityAt(in sessions: [AgentSession]) -> Date? {
        sessions.compactMap(\.lastActivityAt).max()
    }

    nonisolated static func shouldScanLocally(
        agentSessionsEnabled: Bool,
        adaptiveActivityScanningEnabled: Bool,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> Bool
    {
        if agentSessionsEnabled {
            return true
        }
        guard adaptiveActivityScanningEnabled, !lowPowerModeEnabled else { return false }
        return thermalState != .serious && thermalState != .critical
    }

    func start() {
        guard self.localRefreshTask == nil else { return }
        self.localRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLocal()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        self.localRefreshTask?.cancel()
        self.localRefreshTask = nil
    }

    func settingsDidChange() {
        if !self.settings.agentSessionsEnabled {
            // Adaptive keeps only the timestamp signal. Retained session paths and identities
            // remain scoped to the explicitly enabled Agent Sessions UI.
            self.localSessions = []
        }
        guard self.localMonitoringEnabled else {
            self.latestLocalActivityAt = nil
            self.onUpdate?()
            return
        }
        guard !SettingsStore.isRunningTests else { return }
        Task { [weak self] in
            await self?.refreshLocal()
        }
    }

    func refreshOnMenuOpen() {
        guard self.localMonitoringEnabled, !SettingsStore.isRunningTests else { return }
        Task { [weak self] in
            await self?.refreshLocal()
        }
    }

    func focus(_ session: AgentSession) {
        _ = SessionWindowFocuser.focus(session)
    }

    func refreshLocal() async {
        guard self.localMonitoringEnabled, !self.localRefreshInFlight else { return }
        let processInfo = ProcessInfo.processInfo
        guard Self.shouldScanLocally(
            agentSessionsEnabled: self.settings.agentSessionsEnabled,
            adaptiveActivityScanningEnabled: self.settings.adaptiveActivityScanningEnabled,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState)
        else { return }
        self.localRefreshInFlight = true
        let sessions = await self.localScan(self.settings.agentSessionsEnabled)
        self.localRefreshInFlight = false
        guard !Task.isCancelled, self.localMonitoringEnabled else { return }
        self.applyLocalScanResult(sessions)
    }

    func applyLocalScanResult(_ sessions: [AgentSession], updatedAt: Date = Date()) {
        self.latestLocalActivityAt = Self.latestActivityAt(in: sessions)
        self.localSessions = self.settings.agentSessionsEnabled ? sessions : []
        self.lastUpdatedAt = updatedAt
        self.onUpdate?()
    }
}
