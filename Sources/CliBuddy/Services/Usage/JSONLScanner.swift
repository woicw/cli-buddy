import Foundation

/// Generic JSONL file scanner with an in-memory, mtime-keyed cache.
///
/// - Enumerates files under `roots` passing `filter`.
/// - Streams each file line-by-line (no full-file String allocation).
/// - Caches the decoded event array per URL keyed by mtime; on the next
///   scan, files whose mtime hasn't changed skip re-reads entirely.
///
/// Thread-safety: `scan` is async; cache is held by a private actor.
struct JSONLScanner<Event: Sendable> {
    let roots: [URL]
    let filter: @Sendable (URL) -> Bool
    private let cache: Cache

    init(roots: [URL], filter: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.roots = roots
        self.filter = filter
        self.cache = Cache()
    }

    func scan(decode: @escaping @Sendable (Data) -> Event?) async -> [Event] {
        let files = enumerateFiles()
        var collected: [Event] = []
        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date
            if let mtime, let cached = await cache.get(url: url, mtime: mtime) {
                collected.append(contentsOf: cached)
                continue
            }
            let parsed = Self.readAndDecode(url: url, decode: decode)
            if let mtime {
                await cache.put(url: url, mtime: mtime, events: parsed)
            }
            collected.append(contentsOf: parsed)
        }
        return collected
    }

    private func enumerateFiles() -> [URL] {
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

    private actor Cache {
        // Key by mtime truncated to milliseconds to survive round-trips
        // through HFS+/APFS where setAttributes may quantise sub-ms precision.
        private var storage: [URL: (mtimeMs: Int64, events: [Event])] = [:]

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
    }
}
