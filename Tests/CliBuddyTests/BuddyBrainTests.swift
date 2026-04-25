import Testing
import Foundation
import Combine
@testable import CliBuddy

@MainActor
@Suite struct BuddyBrainTests {
    // MARK: - Pure aggregation

    @Test func emptyPhasesIsIdle() {
        #expect(BuddyBrain.mood(for: []) == .idle)
    }

    @Test func processingIsThinking() {
        #expect(BuddyBrain.mood(for: [.processing]) == .thinking)
    }

    @Test func waitingForInputIsWaiting() {
        #expect(BuddyBrain.mood(for: [.waitingForInput]) == .waiting)
    }

    @Test func approvalBeatsProcessing() {
        let pctx = PermissionContext(toolUseId: "x", toolName: "Read", toolInput: nil, receivedAt: Date())
        let phases: [SessionPhase] = [.processing, .waitingForApproval(pctx)]
        #expect(BuddyBrain.mood(for: phases) == .attention)
    }

    @Test func questionBeatsProcessing() {
        let qctx = QuestionContext(toolUseId: "q1", questions: [], receivedAt: Date())
        let phases: [SessionPhase] = [.processing, .waitingForQuestion(qctx)]
        #expect(BuddyBrain.mood(for: phases) == .attention)
    }

    // MARK: - Reactive

    @Test func moodUpdatesWhenStorePublishes() {
        let store = SessionStore()
        let brain = BuddyBrain(store: store)
        #expect(brain.currentMood == .idle)

        let event = HookEvent(
            sessionId: "s1", cwd: "/x", event: "SessionStart", status: "processing",
            pid: nil, tty: nil, tool: nil, toolInput: nil,
            toolUseId: nil, notificationType: nil, message: nil
        )
        store.apply(event)
        #expect(brain.currentMood == .thinking)
    }

    @Test func onAttentionNeededFiresOnApprovalEntry() {
        let store = SessionStore()
        let brain = BuddyBrain(store: store)
        var fired = 0
        brain.onAttentionNeeded = { fired += 1 }

        let approval = HookEvent(
            sessionId: "s1", cwd: "/x", event: "PermissionRequest", status: "waiting_for_approval",
            pid: nil, tty: nil, tool: "Read", toolInput: nil,
            toolUseId: "t1", notificationType: nil, message: nil
        )
        store.apply(approval)
        #expect(fired == 1)

        // Resolving approval shouldn't re-fire when we re-enter non-attention
        let done = HookEvent(
            sessionId: "s1", cwd: "/x", event: "PostToolUse", status: "processing",
            pid: nil, tty: nil, tool: "Read", toolInput: nil,
            toolUseId: "t1", notificationType: nil, message: nil
        )
        store.apply(done)
        #expect(brain.currentMood == .thinking)
        #expect(fired == 1)
    }

    @Test func brainDoesNotRecomputeOnHeartbeat() async {
        let store = SessionStore()
        store.apply(HookEvent(
            sessionId: "s", cwd: "/tmp", event: "SessionStart", status: "processing",
            pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
            notificationType: nil, message: nil
        ))
        let brain = BuddyBrain(store: store)
        var moodChanges = 0
        let c = brain.$currentMood.dropFirst().sink { _ in moodChanges += 1 }

        for _ in 0..<20 {
            store.apply(HookEvent(
                sessionId: "s", cwd: "/tmp", event: "Notification", status: "processing",
                pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
                notificationType: nil, message: nil
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(moodChanges == 0, "Brain recomputed on heartbeats — got \(moodChanges) changes")
        _ = c
    }
}
