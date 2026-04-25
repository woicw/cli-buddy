import Foundation

@MainActor
final class WorkingFeedbackController: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var showSweat = false
    @Published private(set) var currentMessage: String?

    private let startMessages: [String]
    private let finishMessages: [String]
    private let activeMessages: [String]
    private let sweatDuration: TimeInterval
    private let messageVisibleDuration: TimeInterval
    private let activeMessageCooldown: TimeInterval
    private let transitionMessageCooldown: TimeInterval

    private var sweatTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var lastActiveMessageAt: Date?
    private var lastTransitionMessageAt: Date?
    private var startMessageIndex = 0
    private var finishMessageIndex = 0
    private var activeMessageIndex = 0

    init(
        startMessages: [String] = [
            "干活了~",
            "开工啦",
            "忙起来了",
        ],
        finishMessages: [String] = [
            "搞定啦",
            "做完了~",
            "收工一下",
        ],
        activeMessages: [String] = [
            "正在做呢",
            "忙着呢",
            "别催，做着呢",
        ],
        sweatDuration: TimeInterval = 0.9,
        messageVisibleDuration: TimeInterval = 1.2,
        activeMessageCooldown: TimeInterval = 10,
        transitionMessageCooldown: TimeInterval = 5
    ) {
        self.startMessages = startMessages
        self.finishMessages = finishMessages
        self.activeMessages = activeMessages
        self.sweatDuration = sweatDuration
        self.messageVisibleDuration = messageVisibleDuration
        self.activeMessageCooldown = activeMessageCooldown
        self.transitionMessageCooldown = transitionMessageCooldown
    }

    func handlePhaseTransition(from oldPhase: SessionPhase, to newPhase: SessionPhase) {
        let wasWorking = Self.isWorkingPhase(oldPhase)
        let isWorkingNow = Self.isWorkingPhase(newPhase)

        switch (wasWorking, isWorkingNow) {
        case (false, true):
            enterWorking()
        case (true, false):
            exitWorking()
            if Self.isFinishedPhase(newPhase), canShowTransitionMessage() {
                show(message: nextFinishMessage())
            }
        default:
            break
        }
    }

    func handleBuddyTapWhileWorking() {
        guard isWorking else { return }
        let now = Date()
        if let lastActiveMessageAt,
           now.timeIntervalSince(lastActiveMessageAt) < activeMessageCooldown {
            return
        }
        lastActiveMessageAt = now
        show(message: nextActiveMessage())
    }

    func bobOffset(at date: Date) -> CGFloat {
        guard isWorking else { return 0 }
        let phase = Int(floor(date.timeIntervalSinceReferenceDate / 0.35))
        return phase.isMultiple(of: 2) ? 0 : -1
    }

    private func enterWorking() {
        isWorking = true
        triggerSweat()
        if canShowTransitionMessage() {
            show(message: nextStartMessage())
        }
    }

    private func exitWorking() {
        isWorking = false
        showSweat = false
        sweatTask?.cancel()
        sweatTask = nil
    }

    private func triggerSweat() {
        sweatTask?.cancel()
        showSweat = true

        sweatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(sweatDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showSweat = false
        }
    }

    private func show(message: String?) {
        guard let message else { return }
        messageTask?.cancel()
        currentMessage = message

        messageTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(messageVisibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            currentMessage = nil
        }
    }

    private func canShowTransitionMessage(now: Date = Date()) -> Bool {
        if let lastTransitionMessageAt,
           now.timeIntervalSince(lastTransitionMessageAt) < transitionMessageCooldown {
            return false
        }
        lastTransitionMessageAt = now
        return true
    }

    private func nextStartMessage() -> String? {
        nextMessage(from: startMessages, index: &startMessageIndex)
    }

    private func nextFinishMessage() -> String? {
        nextMessage(from: finishMessages, index: &finishMessageIndex)
    }

    private func nextActiveMessage() -> String? {
        nextMessage(from: activeMessages, index: &activeMessageIndex)
    }

    private func nextMessage(from messages: [String], index: inout Int) -> String? {
        guard !messages.isEmpty else { return nil }
        let message = messages[index % messages.count]
        index += 1
        return message
    }

    private static func isWorkingPhase(_ phase: SessionPhase) -> Bool {
        if case .processing = phase { return true }
        return false
    }

    private static func isFinishedPhase(_ phase: SessionPhase) -> Bool {
        if case .waitingForInput = phase { return true }
        return false
    }
}
