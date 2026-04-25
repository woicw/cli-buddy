import Testing
import Foundation
@testable import CliBuddy

@Suite struct CodexUsageServiceTests {
    @Test func takesLastTokenCountLine() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-sample.jsonl")
        try #"""
        {"type":"session_meta","payload":{"model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-04-21T00:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}
        {"type":"event_msg","timestamp":"2026-04-21T00:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"output_tokens":25,"cached_input_tokens":10,"reasoning_output_tokens":3}}}}
        """#.write(to: file, atomically: true, encoding: .utf8)

        let entry = CodexUsageService.reduceRolloutFile(at: file)
        #expect(entry != nil)
        #expect(entry?.outputTokens == 28)
        #expect(entry?.cacheReadTokens == 10)
        #expect(entry?.inputTokens == 20)
    }
}
