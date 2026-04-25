import Foundation
import Testing
@testable import CliBuddy

@Suite struct WorkingFeedbackControllerTests {
    @Test func enteringProcessingShowsStartFeedback() async {
        let controller = await MainActor.run {
            WorkingFeedbackController(
                startMessages: ["干活了~"],
                finishMessages: ["搞定啦"],
                activeMessages: ["忙着呢"],
                sweatDuration: 0.02,
                messageVisibleDuration: 0.05,
                activeMessageCooldown: 1,
                transitionMessageCooldown: 0
            )
        }

        await MainActor.run {
            controller.handlePhaseTransition(from: .idle, to: .processing)
        }

        let initialSweat = await MainActor.run {
            controller.showSweat
        }
        #expect(initialSweat)

        let snapshot = await MainActor.run {
            (controller.isWorking, controller.currentMessage)
        }
        #expect(snapshot.0)
        #expect(snapshot.1 == "干活了~")
    }

    @Test func finishingProcessingShowsFinishMessage() async {
        let controller = await MainActor.run {
            WorkingFeedbackController(
                startMessages: ["干活了~"],
                finishMessages: ["搞定啦"],
                activeMessages: ["忙着呢"],
                sweatDuration: 0.02,
                messageVisibleDuration: 0.05,
                activeMessageCooldown: 1,
                transitionMessageCooldown: 0
            )
        }

        await MainActor.run {
            controller.handlePhaseTransition(from: .idle, to: .processing)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        await MainActor.run {
            controller.handlePhaseTransition(from: .processing, to: .waitingForInput)
        }

        let snapshot = await MainActor.run {
            (controller.isWorking, controller.showSweat, controller.currentMessage)
        }
        #expect(snapshot.0 == false)
        #expect(snapshot.1 == false)
        #expect(snapshot.2 == "搞定啦")
    }

    @Test func activeTapShowsStatusMessageWithCooldown() async {
        let controller = await MainActor.run {
            WorkingFeedbackController(
                startMessages: ["干活了~"],
                finishMessages: ["搞定啦"],
                activeMessages: ["正在做呢"],
                sweatDuration: 0.02,
                messageVisibleDuration: 0.05,
                activeMessageCooldown: 1
            )
        }

        await MainActor.run {
            controller.handlePhaseTransition(from: .idle, to: .processing)
            controller.handleBuddyTapWhileWorking()
        }

        let first = await MainActor.run { controller.currentMessage }
        #expect(first == "正在做呢")

        try? await Task.sleep(nanoseconds: 60_000_000)

        await MainActor.run {
            controller.handleBuddyTapWhileWorking()
        }

        let second = await MainActor.run { controller.currentMessage }
        #expect(second == nil)
    }

    @Test func transitionMessagesAreThrottledForFiveSeconds() async {
        let controller = await MainActor.run {
            WorkingFeedbackController(
                startMessages: ["干活了~"],
                finishMessages: ["搞定啦"],
                activeMessages: ["忙着呢"],
                sweatDuration: 0.02,
                messageVisibleDuration: 0.05,
                activeMessageCooldown: 1,
                transitionMessageCooldown: 5
            )
        }

        await MainActor.run {
            controller.handlePhaseTransition(from: .idle, to: .processing)
        }
        let first = await MainActor.run { controller.currentMessage }
        #expect(first == "干活了~")

        try? await Task.sleep(nanoseconds: 60_000_000)

        await MainActor.run {
            controller.handlePhaseTransition(from: .processing, to: .waitingForInput)
        }
        let second = await MainActor.run { controller.currentMessage }
        #expect(second == nil)
    }
}
