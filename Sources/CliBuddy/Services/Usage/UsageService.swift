import Foundation
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "Usage")

/// One assistant turn's token usage parsed from a Claude Code JSONL
/// session file.
struct UsageEntry: Sendable, Codable {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let cacheReadTokens: Int
    /// `"standard"` (default) or `"fast"`. Claude Code's `/fast` mode
    /// multiplies billable tokens by ~6× — see `UsageEntry.speedMultiplier`.
    let speed: String
    /// `"<message.id>:<requestId>"` when both are present. Used to drop
    /// turns that Claude Code re-emits across resumed/forked JSONL files.
    /// Mirrors ccusage's `createUniqueHash` (apps/ccusage/src/data-loader.ts).
    let dedupKey: String?

    var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }

    var cost: Double {
        let rates = UsageEntry.rates(for: model)
        let raw = Double(inputTokens) * rates.inputPerToken
                + Double(outputTokens) * rates.outputPerToken
                + Double(cacheWrite5mTokens) * rates.cacheWrite5mPerToken
                + Double(cacheWrite1hTokens) * rates.cacheWrite1hPerToken
                + Double(cacheReadTokens) * rates.cacheReadPerToken
        let mult = (speed.lowercased() == "fast") ? rates.fastMultiplier : 1.0
        return raw * mult
    }

    /// Resolves rates from the bundled LiteLLM snapshot first; falls back
    /// to a hardcoded family table if the model is unknown.
    static func rates(for model: String) -> PricingCatalog.Rates {
        if let r = PricingCatalog.shared.rates(for: model) { return r }
        return fallbackRates(for: model)
    }

    /// Last-resort rates when the bundled snapshot doesn't know the model.
    /// Per-million USD figures here mirror the Anthropic / OpenAI public
    /// rate cards as of 2026; cache rates use the standard 1.25× / 2.0× /
    /// 0.1× multipliers off `input`.
    static func fallbackRates(for model: String) -> PricingCatalog.Rates {
        let (inMM, outMM) = pricingPerMillion(for: model)
        let inT = inMM / 1_000_000
        let outT = outMM / 1_000_000
        let m = model.lowercased()
        let isOpusFourPlus = m.contains("opus") && !(m.contains("opus-3") || m.contains("3-opus"))
        return PricingCatalog.Rates(
            inputPerToken: inT,
            outputPerToken: outT,
            cacheWrite5mPerToken: inT * 1.25,
            cacheWrite1hPerToken: inT * 2.0,
            cacheReadPerToken: inT * 0.1,
            fastMultiplier: isOpusFourPlus ? 6.0 : 1.0
        )
    }

    /// Returns (inputPricePerMillion, outputPricePerMillion) in USD.
    /// Used only as a fallback when `PricingCatalog` doesn't know the
    /// model — the catalog is the authoritative source.
    static func pricingPerMillion(for model: String) -> (Double, Double) {
        let m = model.lowercased()
        if m.contains("haiku") {
            if (m.contains("haiku-3") && !m.contains("haiku-3-5")) ||
               (m.contains("3-haiku") && !m.contains("3-5-haiku")) {
                return (0.25, 1.25)
            }
            return (1.0, 5.0)
        }
        if m.contains("opus") {
            if m.contains("opus-3") || m.contains("3-opus") { return (15.0, 75.0) }
            return (5.0, 25.0)
        }
        if m.contains("sonnet")     { return (3.0, 15.0) }
        if m.contains("gpt-5-mini") { return (0.25, 2.0) }
        if m.contains("gpt-5-nano") { return (0.05, 0.4) }
        if m.contains("gpt-5")      { return (1.25, 10.0) }
        if m.contains("gpt-4")      { return (2.50, 10.0) }
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
        cacheWriteTokens += entry.cacheWrite5mTokens + entry.cacheWrite1hTokens
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

    /// One calendar day's deduped usage. `day` is the local start-of-day.
    struct DailyRow: Sendable {
        let day: Date
        let summary: UsageSummary
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
            filter: { $0.pathExtension == "jsonl" },
            cacheURL: Self.cacheURL
        )
    }

    /// `~/Library/Caches/com.cli-buddy/claude-usage.plist`. ~5–7 MB binary
    /// plist for a long-running developer; rebuilt automatically when the
    /// `UsageEntry` shape changes (schema version bump in JSONLScanner).
    private static let cacheURL: URL? = {
        guard let dir = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("com.cli-buddy/claude-usage.plist")
    }()

    /// Scan once, hand the deduped entries back to the caller. Lets the
    /// breakdown + daily-rollup share a single pass over the JSONL files.
    private func scanEntries() async -> [UsageEntry] {
        await Task.detached(priority: .utility) { [scanner] in
            await scanner.scan { data in Self.decodeAssistantLine(data: data) }
        }.value
    }

    /// Kicks off a scan in the background so the disk cache is warm by
    /// the time the user opens the usage bubble. Safe to call multiple
    /// times — the JSONLScanner cache short-circuits repeat work.
    func prefetch() {
        Task.detached(priority: .background) { [scanner] in
            _ = await scanner.scan { data in Self.decodeAssistantLine(data: data) }
        }
    }

    func computeBreakdown() async -> Breakdown {
        let entries = await scanEntries()
        return Self.aggregate(entries: entries)
    }

    /// Per-day cost/token rollup for the last `days` calendar days, newest
    /// first. Applies the same `(message.id, requestId)` dedup as
    /// `computeBreakdown`, so the per-day costs sum to the same totals.
    /// Used by AppDelegate to log a daily distribution for debugging
    /// "why was today so expensive?" style questions.
    func dailyBreakdown(days: Int = 14) async -> [DailyRow] {
        let entries = await scanEntries()
        return Self.dailyRollup(entries: entries, days: days)
    }

    /// Compute both rollups from a single scan — saves the second filesystem
    /// traversal when AppDelegate wants both at once.
    func computeAll(dailyDays: Int = 14) async -> (Breakdown, [DailyRow]) {
        let entries = await scanEntries()
        return (Self.aggregate(entries: entries),
                Self.dailyRollup(entries: entries, days: dailyDays))
    }

    private static func aggregate(entries: [UsageEntry]) -> Breakdown {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfWeek = Date(timeIntervalSinceNow: -7 * 24 * 3600)
        var today = UsageSummary()
        var week = UsageSummary()
        var all = UsageSummary()
        // Claude Code re-emits the same assistant turn into multiple JSONL
        // files when sessions are resumed/forked/compacted, and occasionally
        // even within a single file. Skip turns we have already counted,
        // keyed by (message.id, requestId). ccusage applies the same fix.
        var seen = Set<String>()
        for entry in entries {
            if let key = entry.dedupKey, !seen.insert(key).inserted { continue }
            all.include(entry)
            if entry.timestamp >= startOfWeek { week.include(entry) }
            if entry.timestamp >= startOfToday { today.include(entry) }
        }
        return Breakdown(today: today, week: week, all: all)
    }

    private static func dailyRollup(entries: [UsageEntry], days: Int) -> [DailyRow] {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date(timeIntervalSinceNow: -Double(days) * 24 * 3600))
        var byDay: [Date: UsageSummary] = [:]
        var seen = Set<String>()
        for entry in entries {
            if let key = entry.dedupKey, !seen.insert(key).inserted { continue }
            guard entry.timestamp >= cutoff else { continue }
            let day = cal.startOfDay(for: entry.timestamp)
            byDay[day, default: UsageSummary()].include(entry)
        }
        return byDay
            .map { DailyRow(day: $0.key, summary: $0.value) }
            .sorted { $0.day > $1.day }
    }

    /// Parses one JSONL line; nil for non-assistant lines or missing fields.
    static func decodeAssistantLine(data: Data) -> UsageEntry? {
        struct Line: Decodable {
            let type: String?
            let timestamp: Date?
            let message: Message?
            let requestId: String?
        }
        struct Message: Decodable {
            let id: String?
            let role: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation: CacheCreation?
            let speed: String?
        }
        struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Int?
            let ephemeral_1h_input_tokens: Int?
        }
        guard let line = try? assistantLineDecoder.decode(Line.self, from: data),
              line.type == "assistant",
              let message = line.message,
              let usage = message.usage,
              let timestamp = line.timestamp
        else { return nil }

        // Prefer the per-TTL breakdown when present (5-min vs 1-hour cache
        // are billed at different multiples of the input rate). Fall back
        // to attributing all of cache_creation_input_tokens to 5-min.
        let total = usage.cache_creation_input_tokens ?? 0
        let cw5m: Int
        let cw1h: Int
        if let cc = usage.cache_creation,
           cc.ephemeral_5m_input_tokens != nil || cc.ephemeral_1h_input_tokens != nil {
            cw5m = cc.ephemeral_5m_input_tokens ?? 0
            cw1h = cc.ephemeral_1h_input_tokens ?? 0
        } else {
            cw5m = total
            cw1h = 0
        }

        let dedupKey: String?
        if let mid = message.id, let rid = line.requestId {
            dedupKey = "\(mid):\(rid)"
        } else {
            dedupKey = nil
        }

        return UsageEntry(
            timestamp: timestamp,
            model: message.model ?? "unknown",
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheWrite5mTokens: cw5m,
            cacheWrite1hTokens: cw1h,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            speed: usage.speed ?? "standard",
            dedupKey: dedupKey
        )
    }
}
