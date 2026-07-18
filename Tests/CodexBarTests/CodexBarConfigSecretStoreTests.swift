import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct CodexBarConfigSecretStoreTests {
    @Test
    func `secure save seals every credential shape and round trips`() throws {
        let fileURL = Self.testFileURL("round-trip")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let secretStore = InMemoryConfigSecretStore()
        let store = CodexBarConfigStore(fileURL: fileURL, secretStore: secretStore)
        let accountID = UUID()

        try store.save(Self.secretBearingConfig(accountID: accountID))

        let json = try String(contentsOf: fileURL, encoding: .utf8)
        for secret in Self.secretPlaceholders {
            #expect(!json.contains(secret))
        }
        #expect(json.contains(CodexBarConfigStore.protectedSecretPlaceholder))
        #expect(secretStore.count == 5)

        let loadedConfig = try store.load()
        let loaded = try #require(loadedConfig)
        #expect(loaded.providerConfig(for: .bedrock)?.apiKey == "access-key-placeholder")
        #expect(loaded.providerConfig(for: .bedrock)?.secretKey == "secret-key-placeholder")
        #expect(loaded.providerConfig(for: .bedrock)?.cookieHeader == "cookie-placeholder")
        #expect(loaded.providerConfig(for: .stepfun)?.region == "oasis-token-placeholder")
        #expect(loaded.providerConfig(for: .stepfun)?.tokenAccounts?.accounts.first?.token ==
            "account-token-placeholder")
    }

    @Test
    func `load migrates plaintext only after verified keychain writes`() throws {
        let fileURL = Self.testFileURL("migration")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let accountID = UUID()
        try CodexBarConfigStore(fileURL: fileURL).save(Self.secretBearingConfig(accountID: accountID))
        #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("access-key-placeholder"))

        let secretStore = InMemoryConfigSecretStore()
        let secureStore = CodexBarConfigStore(fileURL: fileURL, secretStore: secretStore)
        let loadedConfig = try secureStore.load()
        let loaded = try #require(loadedConfig)

        #expect(loaded.providerConfig(for: .bedrock)?.apiKey == "access-key-placeholder")
        #expect(secretStore.count == 5)
        let migratedJSON = try String(contentsOf: fileURL, encoding: .utf8)
        for secret in Self.secretPlaceholders {
            #expect(!migratedJSON.contains(secret))
        }
    }

    @Test
    func `failed keychain migration preserves plaintext file`() throws {
        let fileURL = Self.testFileURL("failed-migration")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let accountID = UUID()
        try CodexBarConfigStore(fileURL: fileURL).save(Self.secretBearingConfig(accountID: accountID))

        let secretStore = InMemoryConfigSecretStore(failStores: true)
        let secureStore = CodexBarConfigStore(fileURL: fileURL, secretStore: secretStore)
        let loadedConfig = try secureStore.load()
        let loaded = try #require(loadedConfig)

        #expect(loaded.providerConfig(for: .bedrock)?.apiKey == "access-key-placeholder")
        let unchangedJSON = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(unchangedJSON.contains("access-key-placeholder"))
        #expect(!unchangedJSON.contains(CodexBarConfigStore.protectedSecretPlaceholder))
    }

    @Test
    func `clearing credentials removes stale keychain items after config update`() throws {
        let fileURL = Self.testFileURL("cleanup")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let accountID = UUID()
        let secretStore = InMemoryConfigSecretStore()
        let store = CodexBarConfigStore(fileURL: fileURL, secretStore: secretStore)
        try store.save(Self.secretBearingConfig(accountID: accountID))

        let loadedConfig = try store.load()
        var updated = try #require(loadedConfig)
        var bedrock = try #require(updated.providerConfig(for: .bedrock))
        bedrock.apiKey = nil
        bedrock.secretKey = nil
        bedrock.cookieHeader = nil
        updated.setProviderConfig(bedrock)
        var stepfun = try #require(updated.providerConfig(for: .stepfun))
        stepfun.region = nil
        stepfun.tokenAccounts = nil
        updated.setProviderConfig(stepfun)

        try store.save(updated)

        #expect(secretStore.isEmpty)
        #expect(secretStore.removedCount == 5)
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!json.contains(CodexBarConfigStore.protectedSecretPlaceholder))
    }

    @Test
    func `unprivileged reader fails closed but redacted dump remains available`() throws {
        let fileURL = Self.testFileURL("unprivileged")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let secureStore = CodexBarConfigStore(
            fileURL: fileURL,
            secretStore: InMemoryConfigSecretStore())
        try secureStore.save(Self.secretBearingConfig(accountID: UUID()))

        let unprivilegedStore = CodexBarConfigStore(fileURL: fileURL)
        #expect(throws: CodexBarConfigStoreError.self) {
            _ = try unprivilegedStore.load()
        }
        let redactedConfig = try unprivilegedStore.loadRedacted()
        let redacted = try #require(redactedConfig)
        #expect(redacted.providerConfig(for: .bedrock)?.apiKey == CodexBarConfig.redactedSecretPlaceholder)
        #expect(redacted.providerConfig(for: .stepfun)?.tokenAccounts?.accounts.first?.token ==
            CodexBarConfig.redactedSecretPlaceholder)
    }

    @Test
    func `missing keychain item locks the store against destructive writes`() throws {
        let fileURL = Self.testFileURL("missing-keychain-item")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let secretStore = InMemoryConfigSecretStore()
        let store = CodexBarConfigStore(fileURL: fileURL, secretStore: secretStore)
        try store.save(Self.secretBearingConfig(accountID: UUID()))
        let protectedJSON = try Data(contentsOf: fileURL)

        try secretStore.removeSecret(for: CodexBarConfigSecretKey(provider: .bedrock, kind: .apiKey))

        #expect(throws: CodexBarConfigStoreError.self) {
            _ = try store.load()
        }
        #expect(throws: CodexBarConfigStoreError.self) {
            try store.save(CodexBarConfig.makeDefault())
        }
        #expect(try Data(contentsOf: fileURL) == protectedJSON)
    }

    private static let secretPlaceholders = [
        "access-key-placeholder",
        "secret-key-placeholder",
        "cookie-placeholder",
        "oasis-token-placeholder",
        "account-token-placeholder",
    ]

    private static func secretBearingConfig(accountID: UUID) -> CodexBarConfig {
        CodexBarConfig(providers: [
            ProviderConfig(
                id: .bedrock,
                apiKey: "access-key-placeholder",
                secretKey: "secret-key-placeholder",
                cookieHeader: "cookie-placeholder"),
            ProviderConfig(
                id: .stepfun,
                region: "oasis-token-placeholder",
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [
                        ProviderTokenAccount(
                            id: accountID,
                            label: "Account",
                            token: "account-token-placeholder",
                            addedAt: 0,
                            lastUsed: nil),
                    ],
                    activeIndex: 0)),
        ])
    }

    private static func testFileURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent("CodexBarConfigSecretStoreTests-\(label)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}

private final class InMemoryConfigSecretStore: CodexBarConfigSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CodexBarConfigSecretKey: String] = [:]
    private var removedKeys: Set<CodexBarConfigSecretKey> = []
    private let failStores: Bool

    init(failStores: Bool = false) {
        self.failStores = failStores
    }

    var count: Int {
        self.lock.withLock { self.values.count }
    }

    var isEmpty: Bool {
        self.lock.withLock { self.values.isEmpty }
    }

    var removedCount: Int {
        self.lock.withLock { self.removedKeys.count }
    }

    func loadSecret(for key: CodexBarConfigSecretKey) throws -> String? {
        self.lock.withLock { self.values[key] }
    }

    func storeSecret(_ secret: String, for key: CodexBarConfigSecretKey) throws {
        if self.failStores { throw InMemoryConfigSecretStoreError.storeFailed }
        self.lock.withLock {
            self.values[key] = secret
        }
    }

    func removeSecret(for key: CodexBarConfigSecretKey) throws {
        self.lock.withLock {
            self.values.removeValue(forKey: key)
            self.removedKeys.insert(key)
        }
    }
}

private enum InMemoryConfigSecretStoreError: Error {
    case storeFailed
}
