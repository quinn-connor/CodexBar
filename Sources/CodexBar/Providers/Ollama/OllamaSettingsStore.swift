import CodexBarCore
import Foundation

extension SettingsStore {
    var ollamaCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .ollama)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .ollama) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .ollama, field: "cookieHeader", value: newValue)
        }
    }

    var ollamaCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .ollama, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .ollama) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .ollama, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureOllamaCookieLoaded() {}
}

extension SettingsStore {
    func ollamaSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .OllamaProviderSettings {
        self.resolvedCookieSettings(
            provider: .ollama,
            configuredSource: self.ollamaCookieSource,
            configuredHeader: self.ollamaCookieHeader,
            tokenOverride: tokenOverride)
    }
}
