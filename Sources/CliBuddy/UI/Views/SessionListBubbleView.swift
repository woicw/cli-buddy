import SwiftUI

/// Lists currently known sessions with a color-coded status dot.
/// Tapping a row invokes onJump; × / esc calls onClose.
struct SessionListBubbleView: View {
    @ObservedObject var store: SessionStore
    var onJump: (SessionState) -> Void
    var onClose: () -> Void = {}
    @State private var visibleSessions: [SessionState] = []

    var body: some View {
        BubbleChrome(
            title: "Sessions · \(visibleSessions.count)",
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: 2) {
                if visibleSessions.isEmpty {
                    Text("No active sessions")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(visibleSessions, id: \.sessionId) { session in
                        row(for: session)
                    }
                }
            }
            .frame(width: 320)
        }
        .onAppear(perform: syncSessions)
        .onReceive(store.$tickRevision) { _ in
            syncSessions()
        }
        .onReceive(store.$structuralRevision) { _ in
            syncSessions()
        }
    }

    @ViewBuilder
    private func row(for session: SessionState) -> some View {
        Button {
            onJump(session)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.phase.moodColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: session.phase.moodColor.opacity(0.7), radius: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(session.phase.description)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                if let app = session.terminalApp {
                    Text(app)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
        .padding(.vertical, 1)
    }

    private func syncSessions() {
        visibleSessions = store.sortedSessions
    }
}

private extension SessionPhase {
    var moodColor: Color {
        switch self {
        case .processing:                          return BuddyMood.thinking.color
        case .waitingForApproval, .waitingForQuestion:
                                                   return BuddyMood.attention.color
        case .waitingForInput:                     return BuddyMood.waiting.color
        case .idle, .ended, .compacting:           return BuddyMood.idle.color
        }
    }
}
