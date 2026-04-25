import Foundation
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "Usage")

/// One assistant turn's token usage parsed from a Claude Code JSONL
/// session file.
struct UsageEntry: Sendable {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var cost: Double {
        let (inputRate, outputRate) = UsageEntry.pricing(for: model)
        let inputCost = Double(inputTokens) * inputRate
        let outputCost = Double(outputTokens) * outputRate
        // Cache writes billed at 1.25× input (5-minute cache); cache
        // reads billed at 0.1× input. ccusage uses the same approximation.
        let cacheWriteCost = Double(cacheWriteTokens) * inputRate * 1.25
        let cacheReadCost = Double(cacheReadTokens) * inputRate * 0.1
        return (inputCost + outputCost + cacheWriteCost + cacheReadCost) / 1_000_000
    }

    /// Returns (inputPricePerMillion, outputPricePerMillion) in USD for
    /// the given model. Defaults to Sonnet pricing when unknown.
    static func pricing(for model: String) -> (Double, Double) {
        let m = model.lowercased()
        // Claude
        if m.contains("haiku")  { return (1.0,  5.0) }
        if m.contains("opus")   { return (15.0, 75.0) }
        if m.contains("sonnet") { return (3.0,  15.0) }
        // OpenAI GPT-5 family (Codex). Approximate as of 2026.
        if m.contains("gpt-5-mini")  { return (0.25, 2.0) }
        if m.contains("gpt-5-nano")  { return (0.05, 0.4) }
        if m.contains("gpt-5")       { return (1.25, 10.0) }
        if m.contains("gpt-4")       { return (2.50, 10.0) }
        // Unknown — Claude Sonnet rate as a middle-ground default
        return (3.0, 15.0)
    }
}

/// Aggregated usage summary for a given time window.
struct UsageSummary: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cost: Double = 0
    var messageCount: Int = 0
    /// Cost grouped by model-family label ("opus", "sonnet", "haiku").
    var costByModel: [String: Double] = [:]

    mutating func include(_ entry: UsageEntry) {
        inputTokens += entry.inputTokens
        outputTokens += entry.outputTokens
        cacheWriteTokens += entry.cacheWriteTokens
        cacheReadTokens += entry.cacheReadTokens
        cost += entry.cost
        messageCount += 1
        let family = Self.family(of: entry.model)
        costByModel[family, default: 0] += entry.cost
    }

    private static func family(of model: String) -> String {
        let m = model.lowercased()
        if m.contains("haiku")  { return "haiku" }
        if m.contains("opus")   { return "opus" }
        if m.contains("sonnet") { return "sonnet" }
        return "other"
    }
}

/// Scans Claude Code's JSONL log directory and aggregates token usage
/// into today / this week / all-time buckets. Holds a JSONLScanner so
/// repeated queries on unchanged files skip re-reads (mtime cache).
/// AppDelegate keeps UsageService as an ivar, making the cache app-lifetime.
// @unchecked Sendable: JSONLScanner contains an actor (Cache) so the struct
// is safe across concurrency boundaries despite holding a reference type.
struct UsageService: @unchecked Sendable {
    static let claudeProjectsDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    struct Breakdown: Sendable {
        let today: UsageSummary
        let week: UsageSummary
        let all: UsageSummary
    }

    private static let assistantLineDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Shared scanner instance — cache survives across calls on the same
    /// UsageService instance. AppDelegate keeps UsageService as an ivar
    /// so the cache is app-lifetime.
    private let scanner: JSONLScanner<UsageEntry>

    init() {
        self.scanner = JSONLScanner<UsageEntry>(
            roots: [Self.claudeProjectsDir],
            filter: { $0.pathExtension == "jsonl" }
        )
    }

    func computeBreakdown() async -> Breakdown {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfWeek = Date(timeIntervalSinceNow: -7 * 24 * 3600)

        let entries = await Task.detached(priority: .utility) { [scanner] in
            await scanner.scan { data in
                Self.decodeAssistantLine(data: data)
            }
        }.value

        var today = UsageSummary()
        var week = UsageSummary()
        var all = UsageSummary()
        for entry in entries {
            all.include(entry)
            if entry.timestamp >= startOfWeek { week.include(entry) }
            if entry.timestamp >= startOfToday { today.include(entry) }
        }
        return Breakdown(today: today, week: week, all: all)
    }

    /// Parses one JSONL line; nil for non-assistant lines or missing fields.
    static func decodeAssistantLine(data: Data) -> UsageEntry? {
        struct Line: Decodable {
            let type: String?
            let timestamp: Date?
            let message: Message?
        }
        struct Message: Decodable {
            let role: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
        guard let line = try? assistantLineDecoder.decode(Line.self, from: data),
              line.type == "assistant",
              let message = line.message,
              let usage = message.usage,
              let timestamp = line.timestamp
        else { return nil }

        return UsageEntry(
            timestamp: timestamp,
            model: message.model ?? "unknown",
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0
        )
    }
}
