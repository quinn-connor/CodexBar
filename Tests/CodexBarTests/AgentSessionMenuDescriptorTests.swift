import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct AgentSessionMenuDescriptorTests {
    @Test
    func `fresh settings omit agent sessions until explicitly enabled`() {
        let settings = testSettingsStore(suiteName: "AgentSessionMenuDescriptorTests-default-off")
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let session = Self.session(id: "local", host: "local-mac", activity: Date())

        let buildDescriptor = {
            MenuDescriptor.build(
                provider: .codex,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                agentSessionsEnabled: settings.agentSessionsEnabled,
                localAgentSessions: [session])
        }

        let disabledEntries = buildDescriptor().sections.flatMap(\.entries)
        #expect(!Self.containsAgentSessions(in: disabledEntries))

        settings.agentSessionsEnabled = true

        let enabledEntries = buildDescriptor().sections.flatMap(\.entries)
        #expect(Self.containsAgentSessions(in: enabledEntries))
        #expect(enabledEntries.contains { entry in
            guard case .action(_, .focusAgentSession) = entry else { return false }
            return true
        })
    }

    @Test
    func `adaptive refresh requires consent for local monitoring`() {
        let settings = testSettingsStore(suiteName: "AgentSessionMenuDescriptorTests-adaptive-monitoring")
        settings.agentSessionsEnabled = false
        settings.refreshFrequency = .adaptiveAgentAware
        let sessions = AgentSessionsStore(settings: settings)

        #expect(!sessions.localMonitoringEnabled)
        settings.adaptiveActivityScanConsent = .allowed
        #expect(sessions.localMonitoringEnabled)
        #expect(settings.agentSessionsEnabled == false)

        settings.adaptiveActivityScanConsent = .declined
        #expect(!sessions.localMonitoringEnabled)

        settings.adaptiveActivityScanConsent = .allowed
        settings.refreshFrequency = .adaptive
        #expect(!sessions.localMonitoringEnabled)

        settings.agentSessionsEnabled = true
        #expect(sessions.localMonitoringEnabled)
    }

    @Test
    func `adaptive-only scan retains a timestamp but not session details`() {
        let settings = testSettingsStore(suiteName: "AgentSessionMenuDescriptorTests-adaptive-projection")
        settings.agentSessionsEnabled = false
        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        let store = AgentSessionsStore(settings: settings)
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        let sessions = [
            Self.session(id: "older", host: "local", activity: older),
            Self.session(id: "unknown", host: "local", activity: nil),
            Self.session(id: "newer", host: "local", activity: newer),
        ]

        store.applyLocalScanResult(sessions, updatedAt: newer)

        #expect(store.latestLocalActivityAt == newer)
        #expect(store.localSessions.isEmpty)
        #expect(store.lastUpdatedAt == newer)
    }

    @Test
    func `adaptive-only local scan pauses under power and thermal constraints`() {
        #expect(AgentSessionsStore.shouldScanLocally(
            agentSessionsEnabled: false,
            adaptiveActivityScanningEnabled: true,
            lowPowerModeEnabled: false,
            thermalState: .nominal))
        #expect(!AgentSessionsStore.shouldScanLocally(
            agentSessionsEnabled: false,
            adaptiveActivityScanningEnabled: true,
            lowPowerModeEnabled: true,
            thermalState: .nominal))
        #expect(!AgentSessionsStore.shouldScanLocally(
            agentSessionsEnabled: false,
            adaptiveActivityScanningEnabled: true,
            lowPowerModeEnabled: false,
            thermalState: .serious))
        #expect(!AgentSessionsStore.shouldScanLocally(
            agentSessionsEnabled: false,
            adaptiveActivityScanningEnabled: false,
            lowPowerModeEnabled: false,
            thermalState: .nominal))
        #expect(AgentSessionsStore.shouldScanLocally(
            agentSessionsEnabled: true,
            adaptiveActivityScanningEnabled: false,
            lowPowerModeEnabled: true,
            thermalState: .critical))
    }

    @Test
    func `adaptive-only metadata reads require a detected agent process`() {
        #expect(!LocalAgentSessionScanner.shouldScanSessionMetadata(
            hasAgentProcesses: false,
            includeFileOnlySessions: false))
        #expect(LocalAgentSessionScanner.shouldScanSessionMetadata(
            hasAgentProcesses: true,
            includeFileOnlySessions: false))
        #expect(LocalAgentSessionScanner.shouldScanSessionMetadata(
            hasAgentProcesses: false,
            includeFileOnlySessions: true))
    }

    @Test
    func `revoking adaptive consent clears retained activity`() {
        let settings = testSettingsStore(suiteName: "AgentSessionMenuDescriptorTests-consent-revoked")
        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        let store = AgentSessionsStore(settings: settings)
        store.applyLocalScanResult(
            [Self.session(id: "local", host: "local", activity: Date())])
        #expect(store.latestLocalActivityAt != nil)

        settings.adaptiveActivityScanConsent = .declined
        store.settingsDidChange()

        #expect(store.latestLocalActivityAt == nil)
        #expect(store.localSessions.isEmpty)
    }

    @Test
    func `session section counts and renders local sessions`() {
        let now = Date(timeIntervalSince1970: 1000)
        let local = Self.session(id: "local", host: "local-mac", activity: now.addingTimeInterval(-60))
        let section = MenuDescriptor.agentSessionsSection(localSessions: [local], now: now)

        guard case let .text(header, .headline) = section.entries[0] else {
            Issue.record("Expected session headline")
            return
        }
        #expect(header == "Agent Sessions (1)")
        guard case let .action(localTitle, .focusAgentSession(session)) = section.entries[1] else {
            Issue.record("Expected local session action")
            return
        }
        #expect(localTitle.contains("alpha — codex · cli · 1m"))
        #expect(session.id == local.id)
    }

    @Test
    func `empty local session list reports no sessions`() {
        let section = MenuDescriptor.agentSessionsSection(localSessions: [])

        #expect(section.entries.contains { entry in
            guard case let .unavailable(title, _) = entry else { return false }
            return title == "No agent sessions found"
        })
    }

    private static func session(id: String, host: String, activity: Date?) -> AgentSession {
        AgentSession(
            id: id,
            provider: .codex,
            source: .cli,
            state: .active,
            pid: 42,
            cwd: "/Users/test/alpha",
            projectName: "alpha",
            startedAt: nil,
            lastActivityAt: activity,
            transcriptPath: nil,
            host: host)
    }

    private static func containsAgentSessions(in entries: [MenuDescriptor.Entry]) -> Bool {
        entries.contains { entry in
            guard case let .text(title, .headline) = entry else { return false }
            return title.hasPrefix("Agent Sessions (")
        }
    }
}
