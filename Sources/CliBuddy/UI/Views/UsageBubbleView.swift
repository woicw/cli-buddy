import SwiftUI

/// Shows Claude + Codex token usage across today / last 7 days /
/// all-time. Each platform reads its own local log directory — no
/// network call. Cost is API-equivalent; subscription users don't
/// actually pay per-token.
struct UsageBubbleView: View {
    struct Data {
        let claude: UsageService.Breakdown
        /// `nil` while Codex is still being scanned. Cold scans of
        /// `~/.codex/sessions` can take ~150s on a heavy user; rendering
        /// Claude immediately means the bubble doesn't look frozen.
        let codex: UsageService.Breakdown?
    }

    let data: Data?
    var onRefresh: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        BubbleChrome(title: "Usage", onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                if let d = data {
                    platformSection(title: "Claude Code", breakdown: d.claude)
                    divider().padding(.vertical, 2)
                    if let codex = d.codex {
                        platformSection(title: "Codex", breakdown: codex)
                    } else {
                        codexLoadingSection()
                    }

                    divider().padding(.top, 2)
                    Text("API-equivalent cost — if you're on a subscription (Claude Pro / Max / Team, ChatGPT Plus / Codex), you already paid the flat fee and this number is only a usage indicator.")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                        Text("scanning logs…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }

                HStack {
                    Spacer()
                    Button("Refresh", action: onRefresh)
                        .font(.caption.monospaced())
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 360)
        }
    }

    @ViewBuilder
    private func codexLoadingSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex")
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .tracking(0.6)
            HStack(spacing: 8) {
                ProgressView().progressViewStyle(.circular).scaleEffect(0.55)
                Text("scanning rollouts… (first run only)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func platformSection(title: String, breakdown: UsageService.Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .tracking(0.6)
            row(label: "Today",       summary: breakdown.today)
            row(label: "Last 7 days", summary: breakdown.week)
            row(label: "All time",    summary: breakdown.all)
        }
    }

    @ViewBuilder
    private func row(label: String, summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(String(format: "$%.2f", summary.cost))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(summary.cost > 0 ? .white : .white.opacity(0.35))
            }
            HStack(spacing: 12) {
                stat(label: "in",    value: summary.inputTokens)
                stat(label: "out",   value: summary.outputTokens)
                stat(label: "cache", value: summary.cacheReadTokens + summary.cacheWriteTokens)
                stat(label: "msgs",  value: summary.messageCount)
            }
        }
    }

    @ViewBuilder
    private func stat(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.format(value))
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.85))
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    @ViewBuilder
    private func divider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
    }

    private static func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
