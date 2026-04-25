import Testing
import Foundation
@testable import CliBuddy

@Suite struct UsageServiceTests {
    @Test func summaryHasOutputTokensFromAssistantLine() {
        let line = #"{"type":"assistant","timestamp":"2026-04-21T00:00:00Z","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":2}}}"#
        let data = line.data(using: .utf8)!
        let entry = UsageService.decodeAssistantLine(data: data)
        #expect(entry != nil)
        #expect(entry?.outputTokens == 20)
        #expect(entry?.model == "claude-sonnet-4-6")
    }
}
