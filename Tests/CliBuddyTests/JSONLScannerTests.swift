import Testing
import Foundation
@testable import CliBuddy

@Suite struct JSONLScannerTests {
    private struct Event: Codable, Equatable {
        let v: Int
    }

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jsonl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func scanDecodesEveryLine() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("a.jsonl")
        try #"{"v":1}\#n{"v":2}\#n{"v":3}\#n"#.write(to: f, atomically: true, encoding: .utf8)

        let scanner = JSONLScanner<Event>(roots: [dir], filter: { $0.pathExtension == "jsonl" })
        let events = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events.sorted(by: { $0.v < $1.v }) == [Event(v: 1), Event(v: 2), Event(v: 3)])
    }

    @Test func scanUsesCacheOnUnchangedMtime() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("b.jsonl")
        try #"{"v":1}\#n"#.write(to: f, atomically: true, encoding: .utf8)

        let scanner = JSONLScanner<Event>(roots: [dir], filter: { $0.pathExtension == "jsonl" })
        _ = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })

        // Mutate file content but keep its mtime stable.
        let mtime = try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date
        try #"{"v":999}\#n"#.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime!], ofItemAtPath: f.path)

        let events = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events == [Event(v: 1)], "Cache must short-circuit; got \(events)")
    }

    /// Regression for the slow cold-start path: a fresh scanner with the
    /// same `cacheURL` should pick up the previous run's parsed events
    /// from disk instead of re-reading the source files.
    @Test func diskCacheSurvivesNewScannerInstance() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("d.jsonl")
        try #"{"v":7}\#n"#.write(to: f, atomically: true, encoding: .utf8)
        let cacheURL = dir.appendingPathComponent("cache.plist")

        // First scanner — populates and flushes the disk cache.
        let warm = JSONLScanner<Event>(
            roots: [dir],
            filter: { $0.pathExtension == "jsonl" },
            cacheURL: cacheURL
        )
        _ = await warm.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Second scanner — load from disk, then mutate the file but
        // pin its mtime so the disk-cached events should win.
        let mtime = try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date
        try #"{"v":999}\#n"#.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime!], ofItemAtPath: f.path)

        let cold = JSONLScanner<Event>(
            roots: [dir],
            filter: { $0.pathExtension == "jsonl" },
            cacheURL: cacheURL
        )
        let events = await cold.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events == [Event(v: 7)], "disk cache should serve the previously parsed events")
    }

    @Test func scanReloadsOnMtimeChange() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("c.jsonl")
        try #"{"v":1}\#n"#.write(to: f, atomically: true, encoding: .utf8)

        let scanner = JSONLScanner<Event>(roots: [dir], filter: { $0.pathExtension == "jsonl" })
        _ = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })

        try #"{"v":2}\#n"#.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)

        let events = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events == [Event(v: 2)])
    }
}
