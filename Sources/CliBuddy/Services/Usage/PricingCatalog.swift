import Foundation
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "Pricing")

/// Bundled snapshot of BerriAI/litellm's `model_prices_and_context_window.json`.
///
/// Filtered to bare Claude / GPT model ids (no `bedrock/...`, `vertex_ai/...`,
/// `eu.anthropic.*`, etc.) so lookups match the strings Claude Code and
/// Codex actually write into JSONL `message.model`.
///
/// Refresh with `scripts/refresh-pricing.sh`. Doing it manually keeps the
/// "no network calls" promise from the README.
struct PricingCatalog: Sendable {
    /// Per-token rates in USD. All cache fields fall back to a multiple of
    /// `inputPerToken` when LiteLLM hasn't published a separate rate.
    struct Rates: Sendable {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheWrite5mPerToken: Double
        let cacheWrite1hPerToken: Double
        let cacheReadPerToken: Double
        /// `provider_specific_entry.fast` from LiteLLM. 1.0 when the model
        /// has no separate fast tier; 6.0 for current Opus 4.x.
        let fastMultiplier: Double
    }

    static let shared = PricingCatalog()

    private let models: [String: Rates]

    private init() {
        guard let url = Bundle.module.url(forResource: "litellm-pricing", withExtension: "json") else {
            logger.warning("litellm-pricing.json missing from bundle")
            self.models = [:]
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            logger.warning("failed to read litellm-pricing.json")
            self.models = [:]
            return
        }
        struct File: Decodable {
            let models: [String: ModelEntry]
        }
        struct ModelEntry: Decodable {
            let input_cost_per_token: Double?
            let output_cost_per_token: Double?
            let cache_creation_input_token_cost: Double?
            let cache_creation_input_token_cost_above_1hr: Double?
            let cache_read_input_token_cost: Double?
            let provider_specific_entry: ProviderEntry?
        }
        struct ProviderEntry: Decodable {
            let fast: Double?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            logger.warning("failed to decode litellm-pricing.json")
            self.models = [:]
            return
        }
        var out: [String: Rates] = [:]
        out.reserveCapacity(file.models.count)
        for (name, m) in file.models {
            guard let inT = m.input_cost_per_token,
                  let outT = m.output_cost_per_token else { continue }
            var cacheWrite1h = m.cache_creation_input_token_cost_above_1hr
                              ?? (m.cache_creation_input_token_cost.map { $0 * (2.0 / 1.25) }
                                  ?? (inT * 2.0))
            // Guard against upstream data-quality outliers. 1h cache writes
            // are normally 2× input; LiteLLM has shipped bad values (e.g.
            // claude-3-haiku-20240307 listed at ~24× input). Clamp anything
            // beyond 4× back to the normal 2× so a stale snapshot can't
            // wildly inflate a user's cost.
            if cacheWrite1h > inT * 4 {
                logger.warning("clamping implausible 1h cache rate for \(name, privacy: .public): \(cacheWrite1h) → \(inT * 2)")
                cacheWrite1h = inT * 2
            }
            out[name] = Rates(
                inputPerToken: inT,
                outputPerToken: outT,
                cacheWrite5mPerToken: m.cache_creation_input_token_cost ?? (inT * 1.25),
                cacheWrite1hPerToken: cacheWrite1h,
                cacheReadPerToken: m.cache_read_input_token_cost ?? (inT * 0.1),
                fastMultiplier: m.provider_specific_entry?.fast ?? 1.0
            )
        }
        self.models = out
        logger.info("loaded pricing for \(out.count) models")
    }

    /// Look up rates for a model id. Tries an exact match first, then
    /// progressively strips trailing `-…` segments — `claude-opus-4-7-20260416`
    /// resolves to `claude-opus-4-7` when the date-stamped variant is absent.
    func rates(for model: String) -> Rates? {
        if let exact = models[model] { return exact }
        var parts = model.split(separator: "-").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let r = models[parts.joined(separator: "-")] { return r }
        }
        return nil
    }
}
