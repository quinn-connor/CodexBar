import Foundation

public enum OllamaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .ollama,
            metadata: ProviderMetadata(
                id: .ollama,
                displayName: "Ollama",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Ollama usage",
                cliName: "ollama",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://ollama.com/settings",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .ollama,
                iconResourceName: "ProviderIcon-ollama",
                color: ProviderColor(red: 136 / 255, green: 136 / 255, blue: 136 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Ollama cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "ollama",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto, .web, .api:
            [OllamaStatusFetchStrategy()]
        case .cli, .oauth:
            []
        }
    }
}

struct OllamaStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "ollama.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.ollama?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = OllamaUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let isManualMode = context.settings?.ollama?.cookieSource == .manual
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.ollama).verbose(msg) }
            : nil
        let snap = try await fetcher.fetch(
            cookieHeaderOverride: manual,
            manualCookieMode: isManualMode,
            logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.ollama?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.ollama?.manualCookieHeader)
    }
}
