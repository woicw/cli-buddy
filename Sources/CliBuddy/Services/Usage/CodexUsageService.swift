import Foundation
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "CodexUsage")

/// Scans Codex rollout JSONL files for per-session token totals.
/// Each file's LAST `token_count` event is the cumulative session
/// total; earlier events hold running subtotals and are ignored.
///
/// Reuses `JSONLScanner` for mtime-keyed disk caching — completed
/// rollout files have stable mtimes, so on warm starts only the
/// currently-active sessions need re-parsing.
struct CodexUsageService: Sendable {
    static let sessionDirs: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions"),
    ]

    private let scanner: JSONLScanner<UsageEntry>

    init() {
        self.scanner = JSONLScanner<UsageEntry>(
            roots: Self.sessionDirs,
            filter: { $0.lastPathComponent.hasPrefix("rollout-") },
            cacheURL: Self.cacheURL
        )
    }

    private static let cacheURL: URL? = {
        guard let dir = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("com.cli-buddy/codex-usage.plist")
    }()

    func computeBreakdown() async -> UsageService.Breakdown {
        let entries = await Task.detached(priority: .utility) { [scanner] in
            await scanner.scan(parseFile: { url in
                Self.reduceRolloutFile(at: url).map { [$0] } ?? []
            })
        }.value

        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfWeek = Date(timeIntervalSinceNow: -7 * 24 * 3600)
        var today = UsageSummary()
        var week = UsageSummary()
        var all = UsageSummary()
        for entry in entries {
            all.include(entry)
            if entry.timestamp >= startOfWeek { week.include(entry) }
            if entry.timestamp >= startOfToday { today.include(entry) }
        }
        return UsageService.Breakdown(today: today, week: week, all: all)
    }

    /// Mirrors `UsageService.prefetch` — kicks off the scan in the background
    /// at app launch so the first ⌘U press doesn't pay a cold-scan tax.
    func prefetch() {
        Task.detached(priority: .background) { [scanner] in
            _ = await scanner.scan(parseFile: { url in
                Self.reduceRolloutFile(at: url).map { [$0] } ?? []
            })
        }
    }

    /// Streams a rollout file in 64KiB chunks, returns the LAST
    /// token_count event re-mapped to a UsageEntry. Returns nil if the
    /// file contains no usable token_count record.
    static func reduceRolloutFile(at url: URL) -> UsageEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var model = "gpt-5"
        var lastUsage: TokenCountInfo?
        var lastTimestamp: Date?

        var leftover = Data()
        let chunkSize = 64 * 1024
        while true {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0a) {
                let line = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                guard !line.isEmpty else { continue }
                processLine(line, model: &model, lastUsage: &lastUsage, lastTimestamp: &lastTimestamp)
            }
        }
        if !leftover.isEmpty {
            processLine(leftover, model: &model, lastUsage: &lastUsage, lastTimestamp: &lastTimestamp)
        }

        guard let usage = lastUsage, let ts = lastTimestamp else { return nil }
        let cached = usage.cached_input_tokens ?? 0
        let totalInput = usage.input_tokens ?? 0
        let freshInput = max(0, totalInput - cached)
        let output = (usage.output_tokens ?? 0) + (usage.reasoning_output_tokens ?? 0)
        return UsageEntry(
            timestamp: ts,
            model: model,
            inputTokens: freshInput,
            outputTokens: output,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            cacheReadTokens: cached,
            speed: "standard",
            dedupKey: nil
        )
    }

    /// Shared decoder — sequential per-file use is safe.
    private static let rolloutDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func processLine(
        _ line: Data,
        model: inout String,
        lastUsage: inout TokenCountInfo?,
        lastTimestamp: inout Date?
    ) {
        if let meta = try? rolloutDecoder.decode(SessionMetaLine.self, from: line),
           meta.type == "session_meta",
           let m = meta.payload?.model {
            model = m
        }
        if let event = try? rolloutDecoder.decode(EventMsgLine.self, from: line),
           event.type == "event_msg",
           event.payload?.type == "token_count",
           let info = event.payload?.info?.total_token_usage {
            lastUsage = info
            lastTimestamp = event.timestamp
        }
    }

    // MARK: - Decoding shapes

    private struct SessionMetaLine: Decodable {
        let type: String?
        let payload: Payload?
        struct Payload: Decodable { let model: String? }
    }
    private struct EventMsgLine: Decodable {
        let type: String?
        let timestamp: Date?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: Info?
        }
        struct Info: Decodable { let total_token_usage: TokenCountInfo? }
    }
    private struct TokenCountInfo: Decodable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let output_tokens: Int?
        let reasoning_output_tokens: Int?
    }
}
