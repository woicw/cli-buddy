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

    /// 1-hour cache writes are billed at 2× the input rate; 5-min at 1.25×.
    /// Without splitting them the bill is silently undercounted.
    @Test func costSplitsFiveMinuteVersusOneHourCache() {
        let line = #"{"type":"assistant","timestamp":"2026-04-21T00:00:00Z","requestId":"req_a","message":{"id":"msg_a","role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}}}"#
        let entry = UsageService.decodeAssistantLine(data: line.data(using: .utf8)!)!
        // 1M tokens of 1-hour cache write on Opus 4.x ($5/M input × 2.0) = $10.00.
        #expect(abs(entry.cost - 10.0) < 0.001)
        #expect(entry.cacheWrite1hTokens == 1000000)
        #expect(entry.cacheWrite5mTokens == 0)
    }

    /// `(message.id, requestId)` is captured so resumed/forked sessions can
    /// be deduplicated upstream — the field had previously been dropped,
    /// causing ~2× inflation in long-lived projects.
    @Test func decoderCapturesDedupKey() {
        let line = #"{"type":"assistant","timestamp":"2026-04-21T00:00:00Z","requestId":"req_x","message":{"id":"msg_y","role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1,"output_tokens":1}}}"#
        let entry = UsageService.decodeAssistantLine(data: line.data(using: .utf8)!)!
        #expect(entry.dedupKey == "msg_y:req_x")
    }

    /// Opus 4.x is $5/$25 per million tokens — Anthropic dropped the legacy
    /// 3.x rate ($15/$75) starting with the 4.x family. Confirmed against
    /// LiteLLM's `model_prices_and_context_window.json`.
    @Test func opusFourPricingMatchesLiteLLM() {
        let r47 = UsageEntry.rates(for: "claude-opus-4-7")
        #expect(abs(r47.inputPerToken - 5e-6) < 1e-12)
        #expect(abs(r47.outputPerToken - 25e-6) < 1e-12)
        let r46 = UsageEntry.rates(for: "claude-opus-4-6")
        #expect(abs(r46.inputPerToken - 5e-6) < 1e-12)
        #expect(abs(r46.outputPerToken - 25e-6) < 1e-12)
        let r3 = UsageEntry.rates(for: "claude-3-opus-20240229")
        #expect(abs(r3.inputPerToken - 15e-6) < 1e-12)
        #expect(abs(r3.outputPerToken - 75e-6) < 1e-12)
    }

    /// The bundled LiteLLM snapshot is the authoritative source. Spot-check
    /// that it loads, that user-relevant models resolve, and that
    /// longest-prefix fallback handles date-stamped variants.
    @Test func pricingCatalogResolvesUserModels() {
        let catalog = PricingCatalog.shared
        // Exact match.
        let opus = catalog.rates(for: "claude-opus-4-7")
        #expect(opus != nil)
        #expect(opus?.fastMultiplier == 6.0)
        // Date-stamped variant not in snapshot → strips trailing segments.
        let dated = catalog.rates(for: "claude-opus-4-7-20991231")
        #expect(dated != nil)
        #expect(dated?.inputPerToken == opus?.inputPerToken)
    }

    /// LiteLLM's snapshot lists claude-3-haiku-20240307's 1h cache write at
    /// ~24× input — a data-quality outlier. PricingCatalog clamps any 1h
    /// rate beyond 4× input back to the normal 2× so a stale snapshot can't
    /// wildly inflate a user's cost.
    @Test func pricingCatalogClampsOutlierCacheRate() {
        let r = PricingCatalog.shared.rates(for: "claude-3-haiku-20240307")
        #expect(r != nil)
        if let r {
            #expect(r.cacheWrite1hPerToken <= r.inputPerToken * 4)
            #expect(abs(r.cacheWrite1hPerToken - r.inputPerToken * 2) < 1e-12)
        }
    }

    /// `/fast` mode bills Opus 4.x at 6× standard — surfaced in JSONL via
    /// `usage.speed = "fast"` (mirrors LiteLLM's `provider_specific_entry.fast`).
    @Test func fastSpeedMultipliesOpusFourCost() {
        let standard = #"{"type":"assistant","timestamp":"2026-04-21T00:00:00Z","requestId":"r","message":{"id":"m","role":"assistant","model":"claude-opus-4-6","usage":{"input_tokens":1000000,"output_tokens":0,"speed":"standard"}}}"#
        let fast = #"{"type":"assistant","timestamp":"2026-04-21T00:00:00Z","requestId":"r","message":{"id":"m","role":"assistant","model":"claude-opus-4-6","usage":{"input_tokens":1000000,"output_tokens":0,"speed":"fast"}}}"#
        let s = UsageService.decodeAssistantLine(data: standard.data(using: .utf8)!)!
        let f = UsageService.decodeAssistantLine(data: fast.data(using: .utf8)!)!
        #expect(abs(s.cost - 5.0) < 0.001)        // 1M × $5/M = $5
        #expect(abs(f.cost - 30.0) < 0.001)       // 6× = $30
    }
}
