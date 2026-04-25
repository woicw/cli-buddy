import Foundation

/// A running Claude Code / Codex session as observed through hook events.
///
/// Captures only what cli-buddy needs to drive the buddy's mood, the
/// session-list bubble, and terminal jumping. Rich chat history,
/// subagent trees, interrupt watchers and tmux targeting are out of
/// scope and deliberately absent.
struct SessionState: Identifiable, Sendable {
    let sessionId: String
    var cwd: String
    var phase: SessionPhase
    var terminalApp: String?
    var tty: String?
    var pid: Int?
    var cmuxWorkspaceId: String?
    var cmuxSurfaceId: String?
    var source: String?
    var lastEventAt: Date

    var id: String { sessionId }

    init(
        sessionId: String,
        cwd: String,
        phase: SessionPhase = .idle,
        terminalApp: String? = nil,
        tty: String? = nil,
        pid: Int? = nil,
        cmuxWorkspaceId: String? = nil,
        cmuxSurfaceId: String? = nil,
        source: String? = nil,
        lastEventAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.phase = phase
        self.terminalApp = terminalApp
        self.tty = tty
        self.pid = pid
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.cmuxSurfaceId = cmuxSurfaceId
        self.source = source
        self.lastEventAt = lastEventAt
    }

    /// Short display label: last path component of cwd, fallback to sessionId prefix.
    var displayName: String {
        guard let trimmed = cwd.nilIfEmpty else { return String(sessionId.prefix(8)) }
        return URL(fileURLWithPath: trimmed).lastPathComponent.nilIfEmpty ?? String(sessionId.prefix(8))
    }

    /// Zombie heuristic: no event within 5 minutes.
    var isZombie: Bool {
        Date().timeIntervalSince(lastEventAt) > 300
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
