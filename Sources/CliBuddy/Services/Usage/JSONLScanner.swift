import Foundation

/// Generic JSONL file scanner with an mtime-keyed cache that persists
/// across app launches.
///
/// - Enumerates files under `roots` passing `filter`.
/// - Streams each file line-by-line (no full-file String allocation).
/// - Caches the decoded event array per URL keyed by mtime; on the next
///   scan, files whose mtime hasn't changed skip re-reads entirely.
/// - When `cacheURL` is set, the in-memory cache is loaded from disk on
///   first use and rewritten after each scan. Without persistence, every
///   cold start re-parses every file (~5s per 200MB on the user's data).
///
/// Thread-safety: `scan` is async; cache is held by a private actor.
struct JSONLScanner<Event: Sendable & Codable> {
    let roots: [URL]
    let filter: @Sendable (URL) -> Bool
    let cacheURL: URL?
    private let cache: Cache
    private let inFlight: InFlight

    init(
        roots: [URL],
        filter: @escaping @Sendable (URL) -> Bool = { _ in true },
        cacheURL: URL? = nil
    ) {
        self.roots = roots
        self.filter = filter
        self.cacheURL = cacheURL
        self.cache = Cache()
        self.inFlight = InFlight()
    }

    /// Scan with a custom per-file parser. Used by callers that need
    /// whole-file reduction (e.g. Codex's "last token_count event wins")
    /// where a per-line decoder doesn't fit.
    ///
    /// Concurrent calls share a single in-flight result — without this,
    /// the launch-time prefetch and the user's first ⌘U would both kick
    /// off independent scans of the same files, doubling cold-start cost.
    func scan(parseFile: @escaping @Sendable (URL) -> [Event]) async -> [Event] {
        let roots = self.roots
        let filter = self.filter
        let cacheURL = self.cacheURL
        let cache = self.cache
        return await inFlight.run {
            await Self.scanInternal(
                roots: roots, filter: filter, cacheURL: cacheURL,
                cache: cache, parseFile: parseFile
            )
        }
    }

    private static func scanInternal(
        roots: [URL],
        filter: @Sendable (URL) -> Bool,
        cacheURL: URL?,
        cache: Cache,
        parseFile: @Sendable (URL) -> [Event]
    ) async -> [Event] {
        // Lazy disk-load on first call. The cache actor will only have its
        // initial empty state if `loadFromDisk` was never invoked, so we
        // unconditionally try here — the actor short-circuits subsequent
        // calls. No-op if `cacheURL` was not provided.
        if let cacheURL { await cache.loadFromDisk(from: cacheURL) }

        let files = Self.enumerateFiles(roots: roots, filter: filter)
        let presentPaths = Set(files.map { $0.path })
        var collected: [Event] = []
        var dirty = false
        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date
            if let mtime, let cached = await cache.get(url: url, mtime: mtime) {
                collected.append(contentsOf: cached)
                continue
            }
            let parsed = parseFile(url)
            if let mtime {
                await cache.put(url: url, mtime: mtime, events: parsed)
                dirty = true
            }
            collected.append(contentsOf: parsed)
        }
        // Drop entries for files that no longer exist on disk.
        let pruned = await cache.prune(keepingPaths: presentPaths)
        if (dirty || pruned > 0), let cacheURL {
            await cache.saveToDisk(to: cacheURL)
        }
        return collected
    }

    /// Convenience for the common "decode every line" pattern.
    func scan(decode: @escaping @Sendable (Data) -> Event?) async -> [Event] {
        await scan(parseFile: { url in Self.readAndDecode(url: url, decode: decode) })
    }

    private static func enumerateFiles(
        roots: [URL],
        filter: (URL) -> Bool
    ) -> [URL] {
        var out: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let u as URL in en where filter(u) {
                out.append(u)
            }
        }
        return out
    }

    /// Stream 64KiB chunks and split on `\n` to avoid allocating the
    /// entire file as a `String`.
    private static func readAndDecode(url: URL, decode: (Data) -> Event?) -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var result: [Event] = []
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
            while let nl = leftover.firstIndex(of: 0x0a) {   // '\n'
                let line = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                guard !line.isEmpty else { continue }
                if let e = decode(line) { result.append(e) }
            }
        }
        if !leftover.isEmpty, let e = decode(leftover) {
            result.append(e)
        }
        return result
    }

    /// Single-flight gate. While a `run` is in progress, additional callers
    /// receive the same `Task` and await its result instead of starting
    /// their own. Critical for cold start: prefetch + bubble can both
    /// trigger a scan, and re-parsing 562 MB of JSONL twice is the
    /// difference between a 150-second wait and a 75-second one.
    private actor InFlight {
        private var task: Task<[Event], Never>?

        func run(_ work: @Sendable @escaping () async -> [Event]) async -> [Event] {
            if let existing = task { return await existing.value }
            let t = Task.detached(priority: .utility, operation: work)
            task = t
            defer { task = nil }
            return await t.value
        }
    }

    private actor Cache {
        // Key by mtime truncated to milliseconds to survive round-trips
        // through HFS+/APFS where setAttributes may quantise sub-ms precision.
        private var storage: [URL: (mtimeMs: Int64, events: [Event])] = [:]
        private var loadedFromDisk = false

        private static func ms(_ d: Date) -> Int64 {
            Int64((d.timeIntervalSince1970 * 1000).rounded())
        }

        func get(url: URL, mtime: Date) -> [Event]? {
            guard let entry = storage[url], entry.mtimeMs == Self.ms(mtime) else { return nil }
            return entry.events
        }
        func put(url: URL, mtime: Date, events: [Event]) {
            storage[url] = (Self.ms(mtime), events)
        }

        /// Returns the number of entries removed.
        func prune(keepingPaths paths: Set<String>) -> Int {
            let before = storage.count
            storage = storage.filter { paths.contains($0.key.path) }
            return before - storage.count
        }

        // Disk schema: a single property list with an integer schema version
        // (so we can invalidate the cache when `Event` shape changes) and an
        // array of (path, mtimeMs, events) tuples encoded via Codable.
        private struct DiskFile: Codable {
            let version: Int
            let entries: [DiskEntry]
        }
        private struct DiskEntry: Codable {
            let path: String
            let mtimeMs: Int64
            let events: [Event]
        }
        // Bump when `Event`'s shape changes so old caches get discarded
        // instead of decoding into garbage. Static stored properties are
        // not allowed inside generic types, so this lives as a computed
        // property; the call site treats it as a constant.
        private static var diskSchemaVersion: Int { 1 }

        func loadFromDisk(from url: URL) {
            guard !loadedFromDisk else { return }
            loadedFromDisk = true   // mark first to avoid retry storm on read failure
            guard let data = try? Data(contentsOf: url) else { return }
            guard let file = try? PropertyListDecoder().decode(DiskFile.self, from: data),
                  file.version == Self.diskSchemaVersion else { return }
            for entry in file.entries {
                storage[URL(fileURLWithPath: entry.path)] = (entry.mtimeMs, entry.events)
            }
        }

        func saveToDisk(to url: URL) {
            let entries = storage.map {
                DiskEntry(path: $0.key.path, mtimeMs: $0.value.mtimeMs, events: $0.value.events)
            }
            let file = DiskFile(version: Self.diskSchemaVersion, entries: entries)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(file) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic write so a partial flush (app killed mid-write) can't
            // leave a corrupt cache that breaks every future launch.
            try? data.write(to: url, options: .atomic)
        }
    }
}
