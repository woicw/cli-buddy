import Foundation
import Combine

/// Central store of active Claude Code / Codex sessions.
///
/// Scope: only what the desktop buddy needs — mood input, session-list
/// display, and terminal jumping. Chat-history reconstruction,
/// subagent trees, tmux targeting, and rate-limit monitoring are
/// intentionally out of scope.
///
/// Responsibility:
/// 1. Apply incoming `HookEvent`s → update `SessionState` map using the
///    `SessionPhase` state machine for transition validation.
/// 2. Publish revision counters so subscribers only wake when they
///    need to (see `structuralRevision` / `tickRevision` below).
/// 3. Offer stop-gap queries for session listing and lookup.
///
/// Thread-safety: an `@MainActor` ObservableObject. Hook socket callbacks
/// hop to main via `apply(_:)`, which is `@MainActor`-isolated.
@MainActor
final class SessionStore: ObservableObject {
    /// Read-only snapshot for UI. Subscribers should sink on
    /// `$structuralRevision` or `$tickRevision` instead of observing
    /// the dict directly — structural fires only on session
    /// add/remove/phase-change, tick fires on every applied event.
    private(set) var sessions: [String: SessionState] = [:]

    /// Monotonic counter bumped on add/remove/phase-change.
    @Published private(set) var structuralRevision: UInt64 = 0
    /// Monotonic counter bumped on every applied event (structural + tick).
    @Published private(set) var tickRevision: UInt64 = 0

    private var recycleTimer: Timer?

    init() {}

    /// Fires before a session's phase mutates. Receivers can use the
    /// old/new pair to drive side effects (sounds, bubbles, telemetry).
    /// Must not mutate the store.
    var onPhaseTransition: ((_ session: String, _ from: SessionPhase, _ to: SessionPhase) -> Void)?

    /// Ingest one hook event. Creates or updates the matching session and
    /// runs the `SessionPhase` state machine. Unknown/ended transitions
    /// are logged via `print` (hook into DebugLogger later).
    func apply(_ event: HookEvent) {
        let now = Date()
        let isNew = sessions[event.sessionId] == nil
        var state = sessions[event.sessionId] ?? SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            phase: .idle,
            lastEventAt: now
        )

        // Refresh fields that may arrive later (first event often lacks them)
        state.cwd = event.cwd.isEmpty ? state.cwd : event.cwd
        if let pid = event.pid { state.pid = pid }
        if let tty = event.tty { state.tty = tty }
        if let terminalApp = event.terminalApp { state.terminalApp = terminalApp }
        if let ws = event.cmuxWorkspaceId { state.cmuxWorkspaceId = ws }
        if let surf = event.cmuxSurfaceId { state.cmuxSurfaceId = surf }
        if let src = event.source { state.source = src }
        state.lastEventAt = now

        let previousPhase = state.phase
        let next = event.sessionPhase
        if event.event == "SessionEnd" {
            state.phase = .ended
            sessions[event.sessionId] = state
            tickRevision &+= 1
            structuralRevision &+= 1
            onPhaseTransition?(event.sessionId, previousPhase, .ended)
            return
        }

        if state.phase.canTransition(to: next) {
            state.phase = next
        }
        sessions[event.sessionId] = state
        tickRevision &+= 1
        if isNew || previousPhase != state.phase {
            structuralRevision &+= 1
            onPhaseTransition?(event.sessionId, previousPhase, state.phase)
        }
    }

    /// Inject a session for testing. Not meant for runtime use; prefer `apply(_:)`.
    func seed(_ state: SessionState) {
        sessions[state.sessionId] = state
        structuralRevision &+= 1
        tickRevision &+= 1
    }

    /// Remove ended / zombie sessions older than `cutoff`.
    func pruneZombies(olderThan cutoff: TimeInterval = 1800) {
        let now = Date()
        let before = sessions.count
        sessions = sessions.filter { _, state in
            now.timeIntervalSince(state.lastEventAt) < cutoff
        }
        if sessions.count != before {
            structuralRevision &+= 1
            tickRevision &+= 1
        }
    }

    /// Start a recurring sweep that evicts sessions with no recent events.
    /// Inactive sessions aren't archived — they're dropped outright and
    /// will reappear naturally the next time a hook event arrives.
    func startRecycleTimer(interval: TimeInterval = 300, cutoff: TimeInterval = 300) {
        recycleTimer?.invalidate()
        recycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneZombies(olderThan: cutoff)
            }
        }
    }

    func stopRecycleTimer() {
        recycleTimer?.invalidate()
        recycleTimer = nil
    }

    /// Sessions sorted by lastEventAt (newest first). Ended sessions are
    /// filtered out — the buddy's session list shows live sessions only.
    var sortedSessions: [SessionState] {
        sessions.values
            .filter { $0.phase != .ended }
            .sorted { $0.lastEventAt > $1.lastEventAt }
    }
}
