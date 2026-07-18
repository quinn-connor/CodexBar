import Foundation

public struct CodexBarConfigSecretKey: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case apiKey
        case secretKey
        case cookieHeader
        case stepfunToken
        case tokenAccount(UUID)
    }

    public let provider: UsageProvider
    public let kind: Kind

    public init(provider: UsageProvider, kind: Kind) {
        self.provider = provider
        self.kind = kind
    }

    var account: String {
        let suffix = switch self.kind {
        case .apiKey: "api-key"
        case .secretKey: "secret-key"
        case .cookieHeader: "cookie-header"
        case .stepfunToken: "stepfun-token"
        case let .tokenAccount(id): "token-account/\(id.uuidString.lowercased())"
        }
        return "\(self.provider.rawValue)/\(suffix)"
    }
}

public struct CodexBarConfigStoredSecret: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let value: String
    public let destinationBinding: String

    public init(value: String, destinationBinding: String, version: Int = Self.currentVersion) {
        self.version = version
        self.value = value
        self.destinationBinding = destinationBinding
    }
}

public protocol CodexBarConfigSecretStoring: Sendable {
    func loadSecret(for key: CodexBarConfigSecretKey) throws -> CodexBarConfigStoredSecret?
    func storeSecret(_ secret: CodexBarConfigStoredSecret, for key: CodexBarConfigSecretKey) throws
    func removeSecret(for key: CodexBarConfigSecretKey) throws
}

public enum CodexBarConfigSecretStoreError: LocalizedError, Sendable {
    case accessDisabled
    case invalidData
    case operationFailed(operation: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .accessDisabled:
            "\(AppIdentity.displayName) Keychain access is disabled."
        case .invalidData:
            "An \(AppIdentity.displayName) Keychain item contained invalid data."
        case let .operationFailed(operation, status):
            "\(AppIdentity.displayName) Keychain \(operation) failed with status \(status)."
        }
    }
}

#if os(macOS)
import Security

/// Data Protection Keychain storage for provider credentials owned by the macOS app.
public struct MacOSKeychainConfigSecretStore: CodexBarConfigSecretStoring, Sendable {
    public static let defaultService = AppIdentity.configSecretService

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func loadSecret(for key: CodexBarConfigSecretKey) throws -> CodexBarConfigStoredSecret? {
        try self.requireAccess()
        var query = self.baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        KeychainNoUIQuery.apply(to: &query)

        var result: CFTypeRef?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CodexBarConfigSecretStoreError.operationFailed(operation: "read", status: status)
        }
        guard let data = result as? Data,
              let secret = try? JSONDecoder().decode(CodexBarConfigStoredSecret.self, from: data),
              secret.version == CodexBarConfigStoredSecret.currentVersion
        else {
            throw CodexBarConfigSecretStoreError.invalidData
        }
        return secret
    }

    public func storeSecret(_ secret: CodexBarConfigStoredSecret, for key: CodexBarConfigSecretKey) throws {
        try self.requireAccess()
        let data: Data
        do {
            data = try JSONEncoder().encode(secret)
        } catch {
            throw CodexBarConfigSecretStoreError.invalidData
        }
        var query = self.baseQuery(for: key)
        KeychainNoUIQuery.apply(to: &query)

        let updateStatus = KeychainSecurity.update(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CodexBarConfigSecretStoreError.operationFailed(operation: "update", status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = AppIdentity.configSecretLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = KeychainSecurity.add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexBarConfigSecretStoreError.operationFailed(operation: "add", status: addStatus)
        }
    }

    public func removeSecret(for key: CodexBarConfigSecretKey) throws {
        try self.requireAccess()
        var query = self.baseQuery(for: key)
        KeychainNoUIQuery.apply(to: &query)
        let status = KeychainSecurity.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexBarConfigSecretStoreError.operationFailed(operation: "delete", status: status)
        }
    }

    private func baseQuery(for key: CodexBarConfigSecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func requireAccess() throws {
        guard !KeychainAccessGate.isDisabled else {
            throw CodexBarConfigSecretStoreError.accessDisabled
        }
    }
}
#endif
