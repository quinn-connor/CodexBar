import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ClaudeSettingsStoreTests {
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
}
