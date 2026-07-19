import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct KimiCostUsageTests {
    @Test
    func `K3 model aliases normalize without accepting legacy coding aliases`() {
        #expect(CostUsageScanner.normalizeKimiK3Model("k3") == "kimi-k3")
        #expect(CostUsageScanner.normalizeKimiK3Model("kimi-code/k3") == "kimi-k3")
        #expect(CostUsageScanner.normalizeKimiK3Model("my-kimi/kimi-k3") == "kimi-k3")
        #expect(CostUsageScanner.normalizeKimiK3Model("kimi-for-coding") == nil)
        #expect(CostUsageScanner.normalizeKimiK3Model("kimi-code/kimi-for-coding") == nil)
        #expect(CostUsageScanner.normalizeKimiK3Model("kimi-k2.5") == nil)
    }

    @Test
    func `K3 pricing separates cache hits from uncached input`() {
        let cost = CostUsagePricing.kimiK3CostUSD(
            inputTokens: 1_000_000,
            cacheReadInputTokens: 1_000_000,
            outputTokens: 1_000_000)

        #expect(abs(cost - 18.30) < 0.000_000_001)
    }

    @Test
    func `scanner reports only K3 usage records at API equivalent rates`() throws {
        let environment = try KimiCostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 7, day: 19)
        _ = try environment.writeWire(records: [
            Self.record(
                model: "kimi-code/k3",
                day: day,
                input: 1_000_000,
                cacheRead: 1_000_000,
                output: 1_000_000),
            Self.record(
                model: "kimi-code/kimi-for-coding",
                day: day,
                input: 9_000_000,
                output: 9_000_000),
            ["type": "context.clear", "time": Int64(day.timeIntervalSince1970 * 1000)],
        ])

        var options = CostUsageScanner.Options(
            kimiSessionsRoot: environment.sessionsRoot,
            cacheRoot: environment.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .kimi,
            since: day,
            until: day,
            now: day,
            options: options)

        let entry = try #require(report.data.first)
        #expect(report.data.count == 1)
        #expect(entry.date == "2026-07-19")
        #expect(entry.inputTokens == 1_000_000)
        #expect(entry.cacheReadTokens == 1_000_000)
        #expect(entry.cacheCreationTokens == 0)
        #expect(entry.outputTokens == 1_000_000)
        #expect(entry.totalTokens == 3_000_000)
        #expect(entry.requestCount == 1)
        #expect(abs((entry.costUSD ?? 0) - 18.30) < 0.000_000_001)
        #expect(entry.modelsUsed == ["kimi-k3"])
        #expect(entry.modelBreakdowns?.first?.modelName == "kimi-k3")
    }

    @Test
    func `scanner incrementally adds appended K3 records without recounting the file`() throws {
        let environment = try KimiCostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 7, day: 19)
        let wire = try environment.writeWire(records: [
            Self.record(model: "kimi-code/k3", day: day, input: 100, output: 10),
        ])
        var options = CostUsageScanner.Options(
            kimiSessionsRoot: environment.sessionsRoot,
            cacheRoot: environment.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .kimi,
            since: day,
            until: day,
            now: day,
            options: options)
        try environment.append(
            record: Self.record(model: "my-kimi/kimi-k3", day: day, input: 150, output: 20),
            to: wire)
        let second = CostUsageScanner.loadDailyReport(
            provider: .kimi,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        #expect(first.data.first?.totalTokens == 110)
        #expect(second.data.first?.inputTokens == 250)
        #expect(second.data.first?.outputTokens == 30)
        #expect(second.data.first?.totalTokens == 280)
        #expect(second.data.first?.requestCount == 2)
    }

    @Test
    func `fetcher resolves KIMI CODE HOME and publishes a K3 token snapshot`() async throws {
        let environment = try KimiCostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 7, day: 19)
        _ = try environment.writeWire(records: [
            Self.record(model: "kimi-code/k3", day: day, input: 200, cacheRead: 50, output: 25),
        ])

        var options = CostUsageScanner.Options(cacheRoot: environment.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .kimi,
            environment: [KimiSettingsReader.codeHomeEnvironmentKey: environment.kimiHome.path],
            now: day,
            historyDays: 30,
            allowPricingRefresh: false,
            scannerOptions: options)

        #expect(snapshot.sessionTokens == 275)
        #expect(snapshot.last30DaysTokens == 275)
        #expect(snapshot.daily.first?.modelsUsed == ["kimi-k3"])
        #expect(snapshot.daily.first?.requestCount == 1)
    }

    @Test
    func `Kimi descriptor enables shared cost summaries with a local K3 message`() {
        let config = KimiProviderDescriptor.descriptor.tokenCost

        #expect(config.supportsTokenCost)
        #expect(config.noDataMessage().contains("K3 usage records"))
    }

    @Test
    func `Kimi menu card shows the shared inline cost history dashboard`() throws {
        let now = Date(timeIntervalSince1970: 1_721_342_400)
        let metadata = try #require(ProviderDefaults.metadata[.kimi])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 29_000_000,
            sessionCostUSD: 0,
            last30DaysTokens: 3_500_000_000,
            last30DaysCostUSD: 4195.90,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2024-07-19",
                    inputTokens: 20_000_000,
                    outputTokens: 9_000_000,
                    totalTokens: 29_000_000,
                    costUSD: 384,
                    modelsUsed: ["kimi-k3"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "kimi-k3",
                            costUSD: 384,
                            totalTokens: 29_000_000),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kimi,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.map(\.title) == ["Today", "30d cost", "30d tokens", "Latest tokens"])
        #expect(dashboard.kpis.map(\.value) == ["$0.00", "$4,195.90", "3.5B", "29M"])
        #expect(dashboard.points.map(\.value) == [384])
        #expect(dashboard.detailLines == ["Top model: kimi-k3"])
        #expect(dashboard.currencyCode == "USD")
    }

    @Test
    func `automatic cost source detection includes Kimi Code wire logs`() throws {
        let environment = try KimiCostUsageTestEnvironment()
        defer { environment.cleanup() }
        _ = try environment.writeWire(records: [["type": "metadata"]])

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: [KimiSettingsReader.codeHomeEnvironmentKey: environment.kimiHome.path],
            fileManager: .default,
            homeDirectory: environment.root))
    }

    private static func record(
        model: String,
        day: Date,
        input: Int,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        output: Int) -> [String: Any]
    {
        [
            "type": "usage.record",
            "time": Int64(day.timeIntervalSince1970 * 1000),
            "model": model,
            "usage": [
                "inputOther": input,
                "output": output,
                "inputCacheRead": cacheRead,
                "inputCacheCreation": cacheCreation,
            ],
            "usageScope": "turn",
        ]
    }
}

private struct KimiCostUsageTestEnvironment {
    let root: URL
    let kimiHome: URL
    let sessionsRoot: URL
    let cacheRoot: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-kimi-cost-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        self.kimiHome = root.appendingPathComponent("kimi-home", isDirectory: true)
        self.sessionsRoot = self.kimiHome.appendingPathComponent("sessions", isDirectory: true)
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: self.sessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func makeLocalNoon(year: Int, month: Int, day: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = components.date else {
            throw NSError(domain: "KimiCostUsageTestEnvironment", code: 1)
        }
        return date
    }

    func writeWire(records: [[String: Any]]) throws -> URL {
        let url = self.sessionsRoot
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
            .appendingPathComponent("wire.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try records.reduce(into: Data()) { output, record in
            try output.append(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            output.append(Data("\n".utf8))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    func append(record: [String: Any], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.synchronize()
    }
}
