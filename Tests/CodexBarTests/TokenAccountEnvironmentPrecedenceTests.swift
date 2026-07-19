import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct AlibabaTokenPlanRegionSelectionTests {
    @Test @MainActor
    func `fresh app settings default to International`() {
        let settings = testSettingsStore(suiteName: "AlibabaTokenPlanRegionSelectionTests-fresh")

        #expect(settings.alibabaTokenPlanAPIRegion == .international)
    }

    @Test @MainActor
    func `legacy app settings without region remain China mainland`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .alibabatokenplan, region: nil))
        let settings = testSettingsStore(
            suiteName: "AlibabaTokenPlanRegionSelectionTests-legacy",
            config: config)

        #expect(settings.alibabaTokenPlanAPIRegion == .chinaMainland)
    }

    @Test @MainActor
    func `app settings trim configured region`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .alibabatokenplan, region: " intl "))
        let settings = testSettingsStore(
            suiteName: "AlibabaTokenPlanRegionSelectionTests-trimmed",
            config: config)

        #expect(settings.alibabaTokenPlanAPIRegion == .international)
    }
}

@Suite(.serialized)
@MainActor
struct TokenAccountEnvironmentPrecedenceTests {
    @Test
    func `token account environment overrides config API key in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-app")
        settings.zaiAPIToken = "config-token"
        settings.addTokenAccount(provider: .zai, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .zai,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    @Test
    func `deepseek token account injects environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-deepseek-app")
        settings.addTokenAccount(provider: .deepseek, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .deepseek,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == "account-token")
    }

    @Test
    func `app snapshot override resolves cookie account without mutating stored selection`() throws {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-cookie-override-app")
        settings.cursorCookieSource = .auto
        settings.cursorCookieHeader = "configured=true"
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Override",
            token: "account=true",
            addedAt: 0,
            lastUsed: nil)

        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            settings: settings,
            tokenOverride: TokenAccountOverride(provider: .cursor, account: account))
        let cursorSettings = try #require(snapshot.cursor)

        #expect(cursorSettings.cookieSource == .manual)
        #expect(cursorSettings.manualCookieHeader == "account=true")
        #expect(settings.tokenAccounts(for: .cursor).isEmpty)
    }

    @Test
    func `claude OAuth token account overrides environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-app")
        settings.addTokenAccount(provider: .claude, label: "OAuth", token: "Bearer sk-ant-oat-account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account-token")
    }

    @Test
    func `claude session account strips ambient admin api credentials in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-admin-strip-app")
        settings.claudeAdminAPIKey = "sk-ant-admin-config"
        settings.addTokenAccount(provider: .claude, label: "Session", token: "sk-ant-session-token")

        let env = ProviderRegistry.makeEnvironment(
            base: [
                "FOO": "bar",
                ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-base",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-base",
            ],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
    }

    @Test
    func `claude session key selection carries organization id in app settings snapshot`() throws {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-org-app")
        settings.addTokenAccount(
            provider: .claude,
            label: "Team",
            token: "sk-ant-session-token",
            organizationID: " org-team ")

        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token")
        #expect(claudeSettings.organizationID == "org-team")
    }

    @Test
    func `claude token account organization id uses organizationId JSON key`() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "label": "Team",
          "token": "sk-ant-session-token",
          "addedAt": 0,
          "lastUsed": null,
          "organizationId": "org-team"
        }
        """
        let account = try JSONDecoder().decode(ProviderTokenAccount.self, from: Data(json.utf8))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]

        #expect(account.organizationID == "org-team")
        #expect(encoded?["organizationId"] as? String == "org-team")
        #expect(encoded?["organizationID"] == nil)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
