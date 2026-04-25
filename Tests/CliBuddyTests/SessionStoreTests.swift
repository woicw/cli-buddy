import Testing
import Foundation
import Combine
@testable import CliBuddy

@MainActor
@Suite struct SessionStoreTests {
    private func makeEvent(
        sessionId: String = "s1",
        cwd: String = "/tmp/proj",
        event: String = "SessionStart",
        status: String = "processing"
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: event,
            status: status,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    @Test func applyCreatesSessionWithProcessingPhase() {
        let store = SessionStore()
        store.apply(makeEvent())
        let s = store.sessions["s1"]
        #expect(s != nil)
        #expect(s?.phase == .processing)
        #expect(s?.cwd == "/tmp/proj")
    }

    @Test func applyUpdatesExistingSession() {
        let store = SessionStore()
        store.apply(makeEvent())
        store.apply(makeEvent(event: "Stop", status: "waiting_for_input"))
        #expect(store.sessions["s1"]?.phase == .waitingForInput)
    }

    @Test func sessionEndMovesToEnded() {
        let store = SessionStore()
        store.apply(makeEvent())
        store.apply(makeEvent(event: "SessionEnd", status: "idle"))
        #expect(store.sessions["s1"]?.phase == .ended)
    }

    @Test func pruneRemovesOldSessions() {
        let store = SessionStore()
        store.seed(SessionState(
            sessionId: "old", cwd: "/x", phase: .idle,
            lastEventAt: Date(timeIntervalSinceNow: -3600)
        ))
        store.seed(SessionState(sessionId: "fresh", cwd: "/y", phase: .idle, lastEventAt: Date()))

        store.pruneZombies(olderThan: 1800)
        #expect(store.sessions["old"] == nil)
        #expect(store.sessions["fresh"] != nil)
    }

    @Test func sortedSessionsNewestFirst() {
        let store = SessionStore()
        store.seed(SessionState(
            sessionId: "older", cwd: "/a", lastEventAt: Date(timeIntervalSinceNow: -100)
        ))
        store.seed(SessionState(
            sessionId: "newer", cwd: "/b", lastEventAt: Date()
        ))
        let sorted = store.sortedSessions
        #expect(sorted.first?.sessionId == "newer")
    }

    @Test func sortedSessionsExcludesEnded() {
        let store = SessionStore()
        store.seed(SessionState(
            sessionId: "live", cwd: "/a", phase: .waitingForInput, lastEventAt: Date()
        ))
        store.seed(SessionState(
            sessionId: "done", cwd: "/b", phase: .ended, lastEventAt: Date()
        ))
        let sorted = store.sortedSessions
        #expect(sorted.map(\.sessionId) == ["live"])
    }

    @Test func heartbeatEmitsTickButNotStructural() {
        let store = SessionStore()
        store.apply(makeEvent())                          // phase: processing
        var structuralCount = 0
        var tickCount = 0
        let c1 = store.$structuralRevision.sink { _ in structuralCount += 1 }
        let c2 = store.$tickRevision.sink { _ in tickCount += 1 }
        // Same phase, different time → tick only.
        store.apply(makeEvent(event: "Notification", status: "processing"))
        #expect(structuralCount == 1)  // initial sink value only
        #expect(tickCount == 2)        // initial + one tick
        _ = (c1, c2)
    }

    @Test func phaseChangeEmitsStructural() {
        let store = SessionStore()
        store.apply(makeEvent())                          // processing
        var structuralCount = 0
        let c = store.$structuralRevision.sink { _ in structuralCount += 1 }
        store.apply(makeEvent(event: "Stop", status: "waiting_for_input"))
        #expect(structuralCount == 2)                     // initial + phase change
        _ = c
    }
}
