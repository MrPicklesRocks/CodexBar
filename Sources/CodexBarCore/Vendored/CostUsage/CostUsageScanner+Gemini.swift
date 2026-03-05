import Foundation

extension CostUsageScanner {
    private struct GeminiSessionRecord: Decodable {
        let messages: [GeminiSessionMessage]
    }

    private struct GeminiSessionMessage: Decodable {
        let timestamp: String?
        let type: String?
        let model: String?
        let tokens: GeminiTokenUsage?
    }

    private struct GeminiTokenUsage: Decodable {
        let input: Int?
        let output: Int?
        let cached: Int?
        let thoughts: Int?
        let tool: Int?
        let total: Int?
    }

    private struct GeminiDayUsage {
        var totalTokens: Int = 0
        var modelTokens: [String: Int] = [:]
    }

    static func loadGeminiDaily(range: CostUsageDayRange, options: Options) -> CostUsageDailyReport {
        var byDay: [String: GeminiDayUsage] = [:]
        byDay.reserveCapacity(32)

        let files = self.listGeminiSessionFiles(options: options)
        for file in files {
            self.parseGeminiSessionFile(file, range: range, byDay: &byDay)
        }

        return self.geminiReport(byDay: byDay, range: range)
    }

    private static func defaultGeminiRoot(options: Options) -> URL {
        if let override = options.geminiRoot { return override }
        let env = ProcessInfo.processInfo.environment["GEMINI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    private static func listGeminiSessionFiles(options: Options) -> [URL] {
        let root = self.defaultGeminiRoot(options: options)
            .appendingPathComponent("tmp", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return []
        }

        var result: [URL] = []
        result.reserveCapacity(1024)

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix("session-"),
               fileURL.pathExtension == "json",
               fileURL.path.contains("/chats/")
            {
                result.append(fileURL)
            }
        }
        return result
    }

    private static func parseGeminiSessionFile(
        _ fileURL: URL,
        range: CostUsageDayRange,
        byDay: inout [String: GeminiDayUsage])
    {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let session = try? JSONDecoder().decode(GeminiSessionRecord.self, from: data) else { return }
        guard !session.messages.isEmpty else { return }

        for message in session.messages {
            guard message.type?.localizedCaseInsensitiveCompare("gemini") == .orderedSame else { continue }
            guard let timestamp = message.timestamp,
                  let model = self.normalizedGeminiModelName(message.model)
            else {
                continue
            }
            guard let dayKey = self.dayKeyFromTimestamp(timestamp) ?? self.dayKeyFromParsedISO(timestamp) else {
                continue
            }
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else {
                continue
            }
            guard let tokenTotal = self.geminiTokenTotal(message.tokens), tokenTotal > 0 else { continue }

            var day = byDay[dayKey] ?? GeminiDayUsage()
            day.totalTokens += tokenTotal
            day.modelTokens[model, default: 0] += tokenTotal
            byDay[dayKey] = day
        }
    }

    private static func normalizedGeminiModelName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func geminiTokenTotal(_ tokens: GeminiTokenUsage?) -> Int? {
        guard let tokens else { return nil }
        if let total = tokens.total, total > 0 { return total }

        var sum = 0
        var sawAny = false
        for value in [tokens.input, tokens.output, tokens.cached, tokens.thoughts, tokens.tool] {
            if let value, value > 0 {
                sum += value
                sawAny = true
            }
        }
        return sawAny ? sum : nil
    }

    private static func geminiReport(byDay: [String: GeminiDayUsage], range: CostUsageDayRange) -> CostUsageDailyReport {
        let sortedDayKeys = byDay.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        var entries: [CostUsageDailyReport.Entry] = []
        entries.reserveCapacity(sortedDayKeys.count)

        var totalTokens = 0
        for dayKey in sortedDayKeys {
            guard let day = byDay[dayKey], day.totalTokens > 0 else { continue }
            totalTokens += day.totalTokens

            let sortedModels = day.modelTokens
                .filter { $0.value > 0 }
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }

            let modelsUsed = sortedModels.isEmpty ? nil : sortedModels.map(\.key)
            let modelBreakdowns = sortedModels.isEmpty
                ? nil
                : sortedModels.map { model, tokens in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: nil,
                        totalTokens: tokens)
                }

            entries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: day.totalTokens,
                costUSD: nil,
                modelsUsed: modelsUsed,
                modelBreakdowns: modelBreakdowns))
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: nil,
                totalOutputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: totalTokens,
                totalCostUSD: nil)
        return CostUsageDailyReport(data: entries, summary: summary)
    }
}
