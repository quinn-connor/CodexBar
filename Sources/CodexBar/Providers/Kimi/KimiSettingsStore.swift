import CodexBarCore
import Foundation

extension SettingsStore {
    var kimiUsageDataSource: ProviderSourceMode {
        get {
            switch self.configSnapshot.providerConfig(for: .kimi)?.source ?? .auto {
            case .auto: .auto
            case .cli: .cli
            case .web: .web
            case .api, .oauth: .auto
            }
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .cli: .cli
            case .web: .web
            case .api, .oauth: .auto
            }
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .kimi, field: "usageSource", value: newValue.rawValue)
        }
    }

    var kimiManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .kimi)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .kimi, field: "cookieHeader", value: newValue)
        }
    }

    var kimiCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .kimi, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .kimi, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureKimiAuthTokenLoaded() {}
}

extension SettingsStore {
    func kimiSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.KimiProviderSettings {
        self.ensureKimiAuthTokenLoaded()
        return self.resolvedCookieSettings(
            provider: .kimi,
            configuredSource: self.kimiCookieSource,
            configuredHeader: self.kimiManualCookieHeader,
            tokenOverride: tokenOverride)
    }
}
