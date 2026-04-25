import Foundation
import CoreGraphics

/// Rectangle abstraction so tests can construct synthetic screens without
/// AppKit. The runtime `ScreenManager` adapts `NSScreen.screens` into
/// arrays of `RoamScreen`.
struct RoamScreen: Equatable, Sendable {
    let id: Int
    let frame: CGRect
}

enum RoamMode: Equatable, Sendable {
    case stroll        // wander on the current screen, pausing between legs
    case idle          // sit still (e.g. the user clicked the buddy)
    case summon        // rush to the cursor-screen center and wait
    case sleep         // slumped, zzz animation
    case celebrating   // parabolic hop after a session completion
}

/// Stateless-ish controller driving the buddy's position on a 60fps tick.
///
/// The controller does not own a window; it just computes (target, mode,
/// position) based on the current tick. A `RoamingCoordinator` reads
/// `position` each tick and moves the NSPanel.
@MainActor
final class RoamingController {
    private(set) var screens: [RoamScreen]
    private(set) var mode: RoamMode = .stroll
    var position: CGPoint
    var target: CGPoint

    /// Pixels per second.
    var speed: CGFloat

    /// Seconds remaining to pause before picking the next stroll target.
    private var strollPauseRemaining: TimeInterval = 0

    /// Celebration arc: origin is where the hop started; peak is added
    /// at t=0.5. Resets to stroll when elapsed >= duration.
    private var celebrateOrigin: CGPoint = .zero
    private var celebratePeak: CGFloat = 0
    private var celebrateElapsed: TimeInterval = 0
    private var celebrateDuration: TimeInterval = 0
    /// Mode to restore after celebration (normally .stroll).
    private var celebrateReturnMode: RoamMode = .stroll

    /// Deterministic RNG seed; test-injectable. Production uses
    /// SystemRandomNumberGenerator via nil.
    private var seededRNG: SystemRandomNumberGenerator

    init(
        screens: [RoamScreen],
        initial: CGPoint = .zero,
        speed: CGFloat = 60
    ) {
        self.screens = screens
        self.position = initial
        self.target = initial
        self.speed = speed
        self.seededRNG = SystemRandomNumberGenerator()
    }

    /// Whether the buddy has effectively reached its current target
    /// (within 1pt).
    var reachedTarget: Bool {
        position.distance(to: target) < 1.0
    }

    // MARK: - Mode entry

    /// Enter summon mode, targeting the center of whichever screen holds
    /// the cursor point. If no screen matches (offscreen cursor?), falls
    /// back to the first screen.
    func summon(onScreenAt cursor: CGPoint) {
        mode = .summon
        let screen = screens.first(where: { $0.frame.contains(cursor) }) ?? screens.first
        guard let s = screen else { return }
        target = CGPoint(x: s.frame.midX, y: s.frame.midY)
    }

    /// Stop moving. Used when a bubble is open so the buddy doesn't drift.
    func idle() {
        mode = .idle
        target = position
    }

    /// Put the buddy to sleep in place.
    func sleep() {
        mode = .sleep
        target = position
    }

    /// Begin wandering.
    func startStroll() {
        mode = .stroll
        strollPauseRemaining = 0
        pickStrollTarget()
    }

    /// Hop up and return to starting position over `duration` seconds,
    /// peaking at `peakHeight` points at t=0.5. Drives a parabolic arc
    /// via `tick(deltaTime:)`; no timers, no coordinator state.
    func startCelebration(peakHeight: CGFloat = 30, duration: TimeInterval = 0.35) {
        celebrateOrigin = position
        celebratePeak = peakHeight
        celebrateElapsed = 0
        celebrateDuration = max(0.001, duration)
        celebrateReturnMode = (mode == .summon || mode == .sleep) ? mode : .stroll
        mode = .celebrating
    }

    // MARK: - Per-frame

    /// Advance one frame. `deltaTime` is in seconds.
    func tick(deltaTime: TimeInterval) {
        switch mode {
        case .stroll:
            tickStroll(deltaTime: deltaTime)
        case .idle, .sleep:
            return
        case .summon:
            stepTowardTarget(deltaTime: deltaTime)
        case .celebrating:
            tickCelebrate(deltaTime: deltaTime)
        }
    }

    // MARK: - Private

    private func tickStroll(deltaTime: TimeInterval) {
        if !reachedTarget {
            stepTowardTarget(deltaTime: deltaTime)
            return
        }
        strollPauseRemaining -= deltaTime
        if strollPauseRemaining <= 0 {
            pickStrollTarget()
        }
    }

    private func stepTowardTarget(deltaTime: TimeInterval) {
        let dx = target.x - position.x
        let dy = target.y - position.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 0 else { return }
        let step = min(dist, speed * CGFloat(deltaTime))
        position.x += dx / dist * step
        position.y += dy / dist * step
    }

    private func tickCelebrate(deltaTime: TimeInterval) {
        celebrateElapsed += deltaTime
        let tNorm = min(1, celebrateElapsed / celebrateDuration)
        let offset = 4 * celebratePeak * CGFloat(tNorm) * (1 - CGFloat(tNorm))
        position = CGPoint(x: celebrateOrigin.x, y: celebrateOrigin.y + offset)
        if celebrateElapsed >= celebrateDuration {
            position = celebrateOrigin
            target = celebrateOrigin
            mode = celebrateReturnMode
            if mode == .stroll {
                // Rest at the celebration origin for ~1s before wandering
                // again. pickStrollTarget() is deliberately deferred to
                // tickStroll's natural cadence so the post-hop buddy doesn't
                // snap toward a random point.
                strollPauseRemaining = 1.0
            }
        }
    }

    private func pickStrollTarget() {
        guard let screen = screens.first(where: { $0.frame.contains(position) })
                          ?? screens.first else { return }
        let frame = screen.frame
        let x = CGFloat.random(in: frame.minX...frame.maxX, using: &seededRNG)
        let y = CGFloat.random(in: frame.minY...frame.maxY, using: &seededRNG)
        target = CGPoint(x: x, y: y)
        strollPauseRemaining = .random(in: 1.0...3.0, using: &seededRNG)
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
