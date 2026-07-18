import Foundation

public enum CodexBarConfigStoreError: LocalizedError, Equatable {
    case invalidURL
    case decodeFailed(String)
    case encodeFailed(String)
    case protectedSecretsUnavailable
    case secretVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid \(AppIdentity.displayName) config path."
        case let .decodeFailed(details):
            "Failed to decode \(AppIdentity.displayName) config: \(details)"
        case let .encodeFailed(details):
            "Failed to encode \(AppIdentity.displayName) config: \(details)"
        case .protectedSecretsUnavailable:
            "This \(AppIdentity.displayName) config contains Keychain-protected secrets that are unavailable " +
                "or bound to a different destination."
        case .secretVerificationFailed:
            "\(AppIdentity.displayName) could not verify a credential after writing it to the Keychain."
        }
    }
}

public struct CodexBarConfigStore: @unchecked Sendable {
    public static let pathEnvironmentKey = "CODEXBAR_CONFIG"
    public static let xdgConfigHomeEnvironmentKey = "XDG_CONFIG_HOME"
    public static let protectedSecretPlaceholder = "<keychain>"

    private static let log = CodexBarLog.logger(LogCategories.configStore)

    public let fileURL: URL
    private let fileManager: FileManager
    private let secretStore: (any CodexBarConfigSecretStoring)?
    private let accessState: CodexBarConfigStoreAccessState

    public init(
        fileURL: URL = Self.defaultURL(),
        fileManager: FileManager = .default,
        secretStore: (any CodexBarConfigSecretStoring)? = nil)
    {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.secretStore = secretStore
        self.accessState = CodexBarConfigStoreAccessState()
    }

    public func load() throws -> CodexBarConfig? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        let data = try Data(contentsOf: self.fileURL)
        let decoder = JSONDecoder()
        do {
            let decoded = try decoder.decode(CodexBarConfig.self, from: data).normalized()
            guard let secretStore else {
                guard self.referencedSecretKeys(in: decoded).isEmpty else {
                    self.accessState.markProtectedSecretsUnavailable()
                    throw CodexBarConfigStoreError.protectedSecretsUnavailable
                }
                return decoded
            }

            let hydration: HydrationResult
            do {
                hydration = try self.hydrateSecrets(in: decoded, from: secretStore)
            } catch {
                self.accessState.markProtectedSecretsUnavailable()
                throw error
            }
            if hydration.sawPlaintextSecret {
                do {
                    try self.save(hydration.config)
                } catch {
                    // Migration is fail-safe: keep the original plaintext file until every
                    // Keychain write verifies and the protected JSON replacement succeeds.
                    Self.log.error("Failed to migrate config secrets to Keychain: \(error)")
                }
            }
            return hydration.config.normalized()
        } catch let error as CodexBarConfigStoreError {
            throw error
        } catch {
            throw CodexBarConfigStoreError.decodeFailed(error.localizedDescription)
        }
    }

    public func loadOrCreateDefault() throws -> CodexBarConfig {
        if let existing = try self.load() {
            return existing
        }
        let config = CodexBarConfig.makeDefault()
        try self.save(config)
        return config
    }

    /// Decodes config metadata without resolving Keychain references and strips all secret values.
    public func loadRedacted() throws -> CodexBarConfig? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: self.fileURL)
            return try JSONDecoder().decode(CodexBarConfig.self, from: data)
                .normalized()
                .redactedForDisplay()
        } catch {
            throw CodexBarConfigStoreError.decodeFailed(error.localizedDescription)
        }
    }

    public func save(_ config: CodexBarConfig) throws {
        guard !self.accessState.protectedSecretsUnavailable else {
            throw CodexBarConfigStoreError.protectedSecretsUnavailable
        }
        let normalized = config.normalized()
        let previousReferences = self.loadReferencedSecretKeys()
        let configToPersist: CodexBarConfig
        let desiredSecrets: [CodexBarConfigSecretKey: CodexBarConfigStoredSecret]
        if let secretStore {
            let protected = try self.protectSecrets(in: normalized, store: secretStore)
            try self.storeAndVerify(protected.secrets, in: secretStore)
            configToPersist = protected.config
            desiredSecrets = protected.secrets
        } else {
            guard self.referencedSecretKeys(in: normalized).isEmpty else {
                throw CodexBarConfigStoreError.protectedSecretsUnavailable
            }
            configToPersist = normalized
            desiredSecrets = [:]
        }

        try self.write(configToPersist)

        if let secretStore {
            let staleKeys = previousReferences.subtracting(desiredSecrets.keys)
            for key in staleKeys {
                do {
                    try secretStore.removeSecret(for: key)
                } catch {
                    // The config no longer references this item, so a failed cleanup leaves only
                    // an inaccessible Keychain orphan rather than plaintext or a broken config.
                    Self.log.warning(
                        "Failed to remove stale config credential",
                        metadata: ["provider": key.provider.rawValue])
                }
            }
        }
    }

    private func write(_ config: CodexBarConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw CodexBarConfigStoreError.encodeFailed(error.localizedDescription)
        }
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        try self.applySecurePermissionsIfNeeded()
    }

    public func deleteIfPresent() throws {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
        let references = self.loadReferencedSecretKeys()
        try self.fileManager.removeItem(at: self.fileURL)
        guard let secretStore else { return }
        for key in references {
            try? secretStore.removeSecret(for: key)
        }
    }

    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        if let override = environment[pathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }

        if let xdgConfigHome = environment[xdgConfigHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !xdgConfigHome.isEmpty
        {
            let expanded = (xdgConfigHome as NSString).expandingTildeInPath
            if (expanded as NSString).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent("codexbar", isDirectory: true)
                    .appendingPathComponent("config.json")
            }
        }

        let xdgDefault = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codexbar", isDirectory: true)
            .appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: xdgDefault.path) {
            return xdgDefault
        }

        let legacy = home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }

        return xdgDefault
    }

    private func applySecurePermissionsIfNeeded() throws {
        #if os(macOS) || os(Linux)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }

    private func hydrateSecrets(
        in config: CodexBarConfig,
        from secretStore: any CodexBarConfigSecretStoring) throws -> HydrationResult
    {
        var hydrated = config
        var sawPlaintextSecret = false
        for index in hydrated.providers.indices {
            var provider = hydrated.providers[index]
            let destinationBinding = provider.credentialDestinationBinding
            provider.apiKey = try self.hydratedValue(
                provider.apiKey,
                key: CodexBarConfigSecretKey(provider: provider.id, kind: .apiKey),
                destinationBinding: destinationBinding,
                store: secretStore,
                sawPlaintextSecret: &sawPlaintextSecret)
            provider.secretKey = try self.hydratedValue(
                provider.secretKey,
                key: CodexBarConfigSecretKey(provider: provider.id, kind: .secretKey),
                destinationBinding: destinationBinding,
                store: secretStore,
                sawPlaintextSecret: &sawPlaintextSecret)
            provider.cookieHeader = try self.hydratedValue(
                provider.cookieHeader,
                key: CodexBarConfigSecretKey(provider: provider.id, kind: .cookieHeader),
                destinationBinding: destinationBinding,
                store: secretStore,
                sawPlaintextSecret: &sawPlaintextSecret)
            if provider.id == .stepfun {
                provider.region = try self.hydratedValue(
                    provider.region,
                    key: CodexBarConfigSecretKey(provider: provider.id, kind: .stepfunToken),
                    destinationBinding: destinationBinding,
                    store: secretStore,
                    sawPlaintextSecret: &sawPlaintextSecret)
            }
            if let data = provider.tokenAccounts {
                let accounts = try data.accounts.map { account in
                    let token = try self.hydratedValue(
                        account.token,
                        key: CodexBarConfigSecretKey(provider: provider.id, kind: .tokenAccount(account.id)),
                        destinationBinding: destinationBinding,
                        store: secretStore,
                        sawPlaintextSecret: &sawPlaintextSecret) ?? ""
                    return Self.account(account, replacingTokenWith: token)
                }
                provider.tokenAccounts = ProviderTokenAccountData(
                    version: data.version,
                    accounts: accounts,
                    activeIndex: data.activeIndex)
            }
            hydrated.providers[index] = provider
        }
        return HydrationResult(config: hydrated, sawPlaintextSecret: sawPlaintextSecret)
    }

    private func hydratedValue(
        _ value: String?,
        key: CodexBarConfigSecretKey,
        destinationBinding: String,
        store: any CodexBarConfigSecretStoring,
        sawPlaintextSecret: inout Bool) throws -> String?
    {
        guard let value else { return nil }
        if value == Self.protectedSecretPlaceholder {
            do {
                guard let secret = try store.loadSecret(for: key),
                      secret.destinationBinding == destinationBinding,
                      Self.cleanedSecret(secret.value) != nil
                else {
                    throw CodexBarConfigStoreError.protectedSecretsUnavailable
                }
                return secret.value
            } catch {
                Self.log.error(
                    "Failed to load protected config credential",
                    metadata: ["provider": key.provider.rawValue])
                throw CodexBarConfigStoreError.protectedSecretsUnavailable
            }
        }
        if Self.cleanedSecret(value) != nil {
            sawPlaintextSecret = true
        }
        return value
    }

    private func protectSecrets(
        in config: CodexBarConfig,
        store: any CodexBarConfigSecretStoring) throws -> ProtectionResult
    {
        var protected = config
        var secrets: [CodexBarConfigSecretKey: CodexBarConfigStoredSecret] = [:]
        for index in protected.providers.indices {
            var provider = protected.providers[index]
            let destinationBinding = provider.credentialDestinationBinding
            provider.apiKey = try self.protect(
                provider.sanitizedAPIKey,
                key: CodexBarConfigSecretKey(provider: provider.id, kind: .apiKey),
                destinationBinding: destinationBinding,
                store: store,
                secrets: &secrets)
            provider.secretKey = try self.protect(
                provider.sanitizedSecretKey,
                key: CodexBarConfigSecretKey(provider: provider.id, kind: .secretKey),
                destinationBinding: destinationBinding,
                store: store,
                secrets: &secrets)
            provider.cookieHeader = try self.protect(
                provider.sanitizedCookieHeader,
                key: CodexBarConfigSecretKey(provider: provider.id, kind: .cookieHeader),
                destinationBinding: destinationBinding,
                store: store,
                secrets: &secrets)
            if provider.id == .stepfun {
                provider.region = try self.protect(
                    Self.cleanedSecret(provider.region),
                    key: CodexBarConfigSecretKey(provider: provider.id, kind: .stepfunToken),
                    destinationBinding: destinationBinding,
                    store: store,
                    secrets: &secrets)
            }
            if let data = provider.tokenAccounts {
                let accounts = try data.accounts.map { account in
                    let token = try self.protect(
                        Self.cleanedSecret(account.token),
                        key: CodexBarConfigSecretKey(provider: provider.id, kind: .tokenAccount(account.id)),
                        destinationBinding: destinationBinding,
                        store: store,
                        secrets: &secrets) ?? ""
                    return Self.account(account, replacingTokenWith: token)
                }
                provider.tokenAccounts = ProviderTokenAccountData(
                    version: data.version,
                    accounts: accounts,
                    activeIndex: data.activeIndex)
            }
            protected.providers[index] = provider
        }
        return ProtectionResult(config: protected, secrets: secrets)
    }

    private func storeAndVerify(
        _ secrets: [CodexBarConfigSecretKey: CodexBarConfigStoredSecret],
        in store: any CodexBarConfigSecretStoring) throws
    {
        for (key, secret) in secrets.sorted(by: { $0.key.account < $1.key.account }) {
            try store.storeSecret(secret, for: key)
            guard try store.loadSecret(for: key) == secret else {
                throw CodexBarConfigStoreError.secretVerificationFailed
            }
        }
    }

    private func loadReferencedSecretKeys() -> Set<CodexBarConfigSecretKey> {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let config = try? JSONDecoder().decode(CodexBarConfig.self, from: data)
        else {
            return []
        }
        return self.referencedSecretKeys(in: config)
    }

    private func referencedSecretKeys(in config: CodexBarConfig) -> Set<CodexBarConfigSecretKey> {
        var keys: Set<CodexBarConfigSecretKey> = []
        for provider in config.providers {
            if provider.apiKey == Self.protectedSecretPlaceholder {
                keys.insert(CodexBarConfigSecretKey(provider: provider.id, kind: .apiKey))
            }
            if provider.secretKey == Self.protectedSecretPlaceholder {
                keys.insert(CodexBarConfigSecretKey(provider: provider.id, kind: .secretKey))
            }
            if provider.cookieHeader == Self.protectedSecretPlaceholder {
                keys.insert(CodexBarConfigSecretKey(provider: provider.id, kind: .cookieHeader))
            }
            if provider.id == .stepfun, provider.region == Self.protectedSecretPlaceholder {
                keys.insert(CodexBarConfigSecretKey(provider: provider.id, kind: .stepfunToken))
            }
            for account in provider.tokenAccounts?.accounts ?? []
                where account.token == Self.protectedSecretPlaceholder
            {
                keys.insert(CodexBarConfigSecretKey(provider: provider.id, kind: .tokenAccount(account.id)))
            }
        }
        return keys
    }

    private func protect(
        _ secret: String?,
        key: CodexBarConfigSecretKey,
        destinationBinding: String,
        store: any CodexBarConfigSecretStoring,
        secrets: inout [CodexBarConfigSecretKey: CodexBarConfigStoredSecret]) throws -> String?
    {
        guard let secret else { return nil }
        if secret == Self.protectedSecretPlaceholder {
            guard let existing = try store.loadSecret(for: key),
                  existing.destinationBinding == destinationBinding
            else {
                throw CodexBarConfigStoreError.secretVerificationFailed
            }
            secrets[key] = existing
            return Self.protectedSecretPlaceholder
        }
        secrets[key] = CodexBarConfigStoredSecret(value: secret, destinationBinding: destinationBinding)
        return Self.protectedSecretPlaceholder
    }

    private static func cleanedSecret(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned?.isEmpty ?? true) ? nil : cleaned
    }

    private static func account(
        _ account: ProviderTokenAccount,
        replacingTokenWith token: String) -> ProviderTokenAccount
    {
        ProviderTokenAccount(
            id: account.id,
            label: account.label,
            token: token,
            addedAt: account.addedAt,
            lastUsed: account.lastUsed,
            externalIdentifier: account.externalIdentifier,
            usageScope: account.usageScope,
            organizationID: account.organizationID,
            workspaceID: account.workspaceID)
    }
}

private struct HydrationResult {
    let config: CodexBarConfig
    let sawPlaintextSecret: Bool
}

private struct ProtectionResult {
    let config: CodexBarConfig
    let secrets: [CodexBarConfigSecretKey: CodexBarConfigStoredSecret]
}

private final class CodexBarConfigStoreAccessState: @unchecked Sendable {
    private let lock = NSLock()
    private var secretsUnavailable = false

    var protectedSecretsUnavailable: Bool {
        self.lock.withLock { self.secretsUnavailable }
    }

    func markProtectedSecretsUnavailable() {
        self.lock.withLock {
            self.secretsUnavailable = true
        }
    }
}
