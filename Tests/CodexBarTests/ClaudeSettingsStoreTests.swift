import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ClaudeSettingsStoreTests {
    private func makeStore(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `defaults claude usage source to cli`() throws {
        let suite = "ClaudeSettingsStoreTests-source-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.claudeUsageDataSource == .cli)
    }

    @Test
    func `maps legacy claude auto usage source to cli`() throws {
        let suite = "ClaudeSettingsStoreTests-source-legacy-auto"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [
            ProviderConfig(id: .claude, source: .auto),
        ]))

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.claudeUsageDataSource == .cli)
    }

    @Test
    func `selected claude accounts route explicit CLI default by credential type`() throws {
        let cases: [(token: String, expected: ProviderSourceMode)] = [
            ("Bearer sk-ant-oat-account-token", .oauth),
            ("sk-ant-session-token", .web),
            ("sk-ant-admin-account-token", .api),
        ]

        for (index, testCase) in cases.enumerated() {
            let settings = try self.makeStore(suite: "ClaudeSettingsStoreTests-account-\(index)")
            settings.addTokenAccount(provider: .claude, label: "Account", token: testCase.token)
            let usageStore = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing)

            let context = usageStore.makeFetchContext(provider: .claude, override: nil)

            #expect(context.sourceMode == testCase.expected)
        }
    }
}
