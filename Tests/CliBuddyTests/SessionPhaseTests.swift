import Testing
import Foundation
@testable import CliBuddy

@Suite struct SessionPhaseTests {
    @Test func idleCanTransitionToProcessing() {
        #expect(SessionPhase.idle.canTransition(to: .processing))
    }

    @Test func endedCannotTransitionOut() {
        #expect(!SessionPhase.ended.canTransition(to: .idle))
    }

    @Test func waitingForApprovalCanTransitionToProcessing() {
        let ctx = PermissionContext(
            toolUseId: "x",
            toolName: "Read",
            toolInput: nil,
            receivedAt: Date()
        )
        #expect(SessionPhase.waitingForApproval(ctx).canTransition(to: .processing))
    }

    @Test func needsAttentionFlagsApprovalOnly() {
        let pctx = PermissionContext(
            toolUseId: "x",
            toolName: "Read",
            toolInput: nil,
            receivedAt: Date()
        )
        #expect(SessionPhase.waitingForApproval(pctx).needsAttention)
        #expect(!SessionPhase.processing.needsAttention)
    }
}
