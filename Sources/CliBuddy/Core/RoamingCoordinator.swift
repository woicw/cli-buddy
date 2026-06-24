import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "Roaming")

/// Glues `RoamingController` (pure logic) to the `BuddyWindow` (AppKit)
/// by ticking 60 times per second and moving the panel to
/// `controller.position`. Also honors mode transitions: when a summon
/// arrives + target is reached, the coordinator fires an `onArrived`
/// callback (AppDelegate uses it to pop the approval / question bubble).
@MainActor
final class RoamingCoordinator {
    private(set) var controller: RoamingController
    private let window: BuddyWindow
    private let screens: ScreenManager

    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// True while the user has roaming turned on. Gates `ensureTicking()`
    /// so a parked buddy (idle/sleep) can pause the 60fps timer and resume
    /// on the next mode change — without un-pinning the buddy when roaming
    /// is switched off in settings.
    private var roamingEnabled = false

    /// Fires once when the buddy has just reached a summon target.
    var onSummonArrived: (() -> Void)?

    private var summonHandled = false

    /// While true, `tick()` does nothing. Set during user drag so the
    /// coordinator stops fighting the drag for control of the window
    /// frame (eliminates flicker and stickiness).
    var isSuspended: Bool = false

    init(window: BuddyWindow, screens: ScreenManager, customization: CustomizationStore) {
        self.window = window
        self.screens = screens

        let initialPos = window.frame.origin
        let roamScreens = screens.screens.isEmpty
            ? [RoamScreen(id: 0, frame: NSScreen.main?.frame ?? .zero)]
            : screens.screens

        self.controller = RoamingController(
            screens: roamScreens,
            initial: initialPos,
            speed: Self.pointsPerSecond(for: customization.value.roamSpeed)
        )

        // Pick up screen changes (lid open, monitor plug/unplug).
        screens.$screens
            .sink { [weak self] newScreens in
                guard let self else { return }
                if !newScreens.isEmpty {
                    self.controller = RoamingController(
                        screens: newScreens,
                        initial: self.controller.position,
                        speed: self.controller.speed
                    )
                }
            }
            .store(in: &cancellables)

        // Pick up speed changes from settings.
        customization.$value
            .map(\.roamSpeed)
            .removeDuplicates()
            .sink { [weak self] speed in
                self?.controller.speed = Self.pointsPerSecond(for: speed)
            }
            .store(in: &cancellables)
    }

    func start() {
        roamingEnabled = true
        controller.startStroll()
        ensureTicking()
    }

    func stop() {
        roamingEnabled = false
        ticker?.invalidate()
        ticker = nil
    }

    /// Summon the buddy to the screen holding the cursor. Called by
    /// BuddyBrain's onAttentionNeeded on rising edge into .attention.
    func summonToCursor() {
        let cursor = NSEvent.mouseLocation
        controller.summon(onScreenAt: cursor)
        summonHandled = false
        ensureTicking()
    }

    /// Stop moving — used when a bubble is open so the buddy doesn't
    /// drift away from the anchor point.
    func pauseAtCurrent() {
        controller.idle()
    }

    /// Resume normal wandering.
    func resumeStroll() {
        controller.startStroll()
        ensureTicking()
    }

    /// Align the controller's internal position to the window's actual
    /// origin — used after a user drag so the next tick doesn't yank
    /// the buddy back to where the controller thought it was.
    func syncPositionWithWindow() {
        controller.position = window.frame.origin
        controller.target = window.frame.origin
    }

    /// Hop the buddy up and back down to signal a task completion.
    /// The arc is computed by the controller's .celebrating state; the
    /// coordinator's single ticker moves the panel. No second Timer.
    func celebrate(peakHeight: CGFloat = 30, duration: TimeInterval = 0.35) {
        logger.info("Celebrate bounce starting from origin \(self.window.frame.origin.debugDescription, privacy: .public)")
        controller.startCelebration(peakHeight: peakHeight, duration: duration)
        ensureTicking()
    }

    // MARK: - Private

    /// Start the 60fps ticker if roaming is on and it isn't already
    /// running. The timer fires on the main run loop (this type is
    /// `@MainActor`), so `tick()` runs synchronously via `assumeIsolated`
    /// — no per-frame `Task` allocation.
    private func ensureTicking() {
        guard roamingEnabled, ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !isSuspended else { return }
        controller.tick(deltaTime: 1.0 / 60.0)
        window.place(at: controller.position)

        // Edge: just arrived at a summon target → fire callback once.
        if controller.mode == .summon, controller.reachedTarget, !summonHandled {
            summonHandled = true
            onSummonArrived?()
        }

        // Parked: nothing moves in .idle/.sleep, so pause the ticker
        // instead of spinning at 60fps doing nothing. The entry points
        // (start/resumeStroll/summonToCursor/celebrate) call ensureTicking()
        // to spin it back up on the next mode change.
        if controller.mode == .idle || controller.mode == .sleep {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private static func pointsPerSecond(for speed: RoamSpeed) -> CGFloat {
        switch speed {
        case .slow:   return 30
        case .medium: return 60
        case .fast:   return 120
        }
    }
}
