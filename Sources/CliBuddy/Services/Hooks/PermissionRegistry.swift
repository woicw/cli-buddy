import Foundation

/// Actor-isolated registry of in-flight permission requests. Replaces
/// the NSLock-guarded dictionary that previously lived inside
/// HookSocketServer. Every mutation goes through `await`; no locks.
actor PermissionRegistry {
    private var pending: [String: PendingPermission] = [:]

    func register(_ p: PendingPermission) {
        pending[p.toolUseId] = p
    }

    func remove(toolUseId: String) -> PendingPermission? {
        pending.removeValue(forKey: toolUseId)
    }

    /// Remove and return the most-recently-received pending permission
    /// for a session, or nil.
    func popMostRecent(sessionId: String) -> PendingPermission? {
        let best = pending.values
            .filter { $0.sessionId == sessionId }
            .max(by: { $0.receivedAt < $1.receivedAt })
        if let best { pending.removeValue(forKey: best.toolUseId) }
        return best
    }

    /// Remove every pending permission for a session. Returns the
    /// removed entries so callers can close their sockets.
    func removeAll(sessionId: String) -> [PendingPermission] {
        let matches = pending.filter { $0.value.sessionId == sessionId }
        for (key, _) in matches { pending.removeValue(forKey: key) }
        return Array(matches.values)
    }

    func hasPending(sessionId: String) -> Bool {
        pending.values.contains { $0.sessionId == sessionId }
    }

    func peekPending(sessionId: String) -> PendingPermission? {
        pending.values.first(where: { $0.sessionId == sessionId })
    }

    /// Drain everything — used at shutdown. Returns fd list so callers
    /// can close them on the appropriate queue.
    func drain() -> [PendingPermission] {
        let all = Array(pending.values)
        pending.removeAll()
        return all
    }
}
