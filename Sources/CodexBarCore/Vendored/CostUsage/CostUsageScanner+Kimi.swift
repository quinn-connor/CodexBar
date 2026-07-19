import Foundation

extension CostUsageScanner {
    // MARK: - Kimi K3

    struct KimiParseResult {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
    }

    private struct KimiScanContext {
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let checkCancellation: CancellationCheck?
    }

    private struct KimiFileInfo {
        let url: URL
        let size: Int64
        let mtimeMs: Int64
    }

    private struct KimiUsageRecord: Decodable {
        let type: String
        let time: Double?
        let model: String?
        let usage: KimiTokenUsage?
    }

    private struct KimiTokenUsage: Decodable {
        let inputOther: Int
        let output: Int
        let inputCacheRead: Int
        let inputCacheCreation: Int
    }

    static func defaultKimiSessionsRoot(
        options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        if let override = options.kimiSessionsRoot { return override }
        return KimiSettingsReader.kimiCodeHomeURL(
            environment: environment,
            homeDirectory: homeDirectory)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func normalizeKimiK3Model(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let component = normalized.split(separator: "/").last else { return nil }
        switch component {
        case "k3", "kimi-k3":
            return "kimi-k3"
        default:
            return nil
        }
    }

    static func parseKimiFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0) -> KimiParseResult
    {
        (
            try? self.parseKimiFileCancellable(
                fileURL: fileURL,
                range: range,
                startOffset: startOffset,
                checkCancellation: nil)) ?? KimiParseResult(days: [:], parsedBytes: startOffset)
    }

    static func parseKimiFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        checkCancellation: CancellationCheck?) throws -> KimiParseResult
    {
        var days: [String: [String: [Int]]] = [:]
        let decoder = JSONDecoder()
        let parsedBytes = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: startOffset,
            maxLineBytes: 128 * 1024,
            prefixBytes: 128 * 1024,
            checkCancellation: checkCancellation,
            onLine: { line in
                guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                guard line.bytes.containsAscii(#""usage.record""#) else { return }

                let record: KimiUsageRecord
                do {
                    record = try decoder.decode(KimiUsageRecord.self, from: line.bytes)
                } catch {
                    return
                }

                guard record.type == "usage.record",
                      let model = record.model.flatMap(Self.normalizeKimiK3Model),
                      let usage = record.usage,
                      let milliseconds = record.time,
                      milliseconds.isFinite,
                      milliseconds > 0
                else { return }

                let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
                let dayKey = CostUsageDayRange.dayKey(from: timestamp)
                guard CostUsageDayRange.isInRange(
                    dayKey: dayKey,
                    since: range.scanSinceKey,
                    until: range.scanUntilKey)
                else { return }

                let input = max(0, usage.inputOther)
                let cacheRead = max(0, usage.inputCacheRead)
                let cacheCreation = max(0, usage.inputCacheCreation)
                let output = max(0, usage.output)
                guard input > 0 || cacheRead > 0 || cacheCreation > 0 || output > 0 else { return }

                var dayModels = days[dayKey] ?? [:]
                var packed = dayModels[model] ?? [0, 0, 0, 0, 0]
                packed[0] = (packed[safe: 0] ?? 0) + input
                packed[1] = (packed[safe: 1] ?? 0) + cacheRead
                packed[2] = (packed[safe: 2] ?? 0) + cacheCreation
                packed[3] = (packed[safe: 3] ?? 0) + output
                packed[4] = (packed[safe: 4] ?? 0) + 1
                dayModels[model] = packed
                days[dayKey] = dayModels
            })

        return KimiParseResult(days: days, parsedBytes: parsedBytes)
    }

    static func loadKimiDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let root = self.defaultKimiSessionsRoot(options: options).standardizedFileURL
        let rootFingerprint = [root.path: Int64(0)]
        var cache = CostUsageCacheIO.load(provider: .kimi, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let rootChanged = cache.roots != rootFingerprint
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let shouldRefresh = options.forceRescan
            || rootChanged
            || windowExpanded
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        if shouldRefresh {
            try checkCancellation?()
            let forceFullScan = options.forceRescan || rootChanged || windowExpanded
            if forceFullScan {
                cache = CostUsageCache()
            }

            var touched: Set<String> = []
            try Self.scanKimiRoot(
                root: root,
                context: KimiScanContext(
                    range: range,
                    forceFullScan: forceFullScan,
                    checkCancellation: checkCancellation),
                cache: &cache,
                touched: &touched)
            try checkCancellation?()

            for path in cache.files.keys where !touched.contains(path) {
                cache.files.removeValue(forKey: path)
            }
            Self.rebuildKimiDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.roots = rootFingerprint
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            CostUsageCacheIO.save(provider: .kimi, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildKimiReportFromCache(cache: cache, range: range)
    }

    private static func scanKimiRoot(
        root: URL,
        context: KimiScanContext,
        cache: inout CostUsageCache,
        touched: inout Set<String>) throws
    {
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        for case let url as URL in enumerator {
            try context.checkCancellation?()
            guard url.lastPathComponent == "wire.jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { continue }
            let mtimeMs = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            try Self.processKimiFile(
                file: KimiFileInfo(url: url, size: size, mtimeMs: mtimeMs),
                context: context,
                cache: &cache,
                touched: &touched)
        }
    }

    private static func processKimiFile(
        file: KimiFileInfo,
        context: KimiScanContext,
        cache: inout CostUsageCache,
        touched: inout Set<String>) throws
    {
        let path = file.url.path
        touched.insert(path)

        if let cached = cache.files[path],
           cached.mtimeUnixMs == file.mtimeMs,
           cached.size == file.size,
           !context.forceFullScan
        {
            return
        }

        if let cached = cache.files[path], !context.forceFullScan {
            let startOffset = cached.parsedBytes ?? cached.size
            if file.size > cached.size, startOffset > 0, startOffset <= file.size {
                let delta = try Self.parseKimiFileCancellable(
                    fileURL: file.url,
                    range: context.range,
                    startOffset: startOffset,
                    checkCancellation: context.checkCancellation)
                cache.files[path] = Self.makeFileUsage(
                    mtimeUnixMs: file.mtimeMs,
                    size: file.size,
                    days: Self.mergedKimiDays(cached.days, delta.days),
                    parsedBytes: delta.parsedBytes)
                return
            }
        }

        let parsed = try Self.parseKimiFileCancellable(
            fileURL: file.url,
            range: context.range,
            checkCancellation: context.checkCancellation)
        cache.files[path] = Self.makeFileUsage(
            mtimeUnixMs: file.mtimeMs,
            size: file.size,
            days: parsed.days,
            parsedBytes: parsed.parsedBytes)
    }

    private static func mergedKimiDays(
        _ existing: [String: [String: [Int]]],
        _ delta: [String: [String: [Int]]]) -> [String: [String: [Int]]]
    {
        var merged = existing
        for (day, models) in delta {
            var dayModels = merged[day] ?? [:]
            for (model, packed) in models {
                dayModels[model] = Self.addPacked(a: dayModels[model] ?? [], b: packed, sign: 1)
            }
            merged[day] = dayModels
        }
        return merged
    }

    private static func rebuildKimiDays(cache: inout CostUsageCache) {
        cache.days = [:]
        for file in cache.files.values {
            applyFileDays(cache: &cache, fileDays: file.days, sign: 1)
        }
    }

    private static func buildKimiReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var totalOutput = 0
        var totalTokens = 0
        var totalCost = 0.0

        let dayKeys = cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            let modelNames = models.keys.sorted()
            var dayInput = 0
            var dayCacheRead = 0
            var dayCacheCreation = 0
            var dayOutput = 0
            var dayRequests = 0
            var dayCost = 0.0
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []

            for model in modelNames {
                let packed = models[model] ?? []
                let input = packed[safe: 0] ?? 0
                let cacheRead = packed[safe: 1] ?? 0
                let cacheCreation = packed[safe: 2] ?? 0
                let output = packed[safe: 3] ?? 0
                let requests = packed[safe: 4] ?? 0
                let tokens = input + cacheRead + cacheCreation + output
                let cost = CostUsagePricing.kimiK3CostUSD(
                    inputTokens: input,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreation,
                    outputTokens: output)

                dayInput += input
                dayCacheRead += cacheRead
                dayCacheCreation += cacheCreation
                dayOutput += output
                dayRequests += requests
                dayCost += cost
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: tokens,
                    requestCount: requests))
            }

            let dayTokens = dayInput + dayCacheRead + dayCacheCreation + dayOutput
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead,
                cacheCreationTokens: dayCacheCreation,
                totalTokens: dayTokens,
                requestCount: dayRequests,
                costUSD: dayCost,
                modelsUsed: modelNames,
                modelBreakdowns: Self.sortedModelBreakdowns(breakdowns)))

            totalInput += dayInput
            totalCacheRead += dayCacheRead
            totalCacheCreation += dayCacheCreation
            totalOutput += dayOutput
            totalTokens += dayTokens
            totalCost += dayCost
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: totalCacheCreation,
                totalTokens: totalTokens,
                totalCostUSD: totalCost)
        return CostUsageDailyReport(data: entries, summary: summary)
    }
}
