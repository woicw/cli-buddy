import Testing
import Foundation
import CoreGraphics
@testable import CliBuddy

@MainActor
@Suite struct RoamingControllerTests {
    private let fullHD = RoamScreen(id: 0, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let secondary = RoamScreen(id: 1, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))

    @Test func initialModeIsStroll() {
        let rc = RoamingController(screens: [fullHD])
        #expect(rc.mode == .stroll)
    }

    @Test func summonSetsModeAndTargetToCursorScreenCenter() {
        let rc = RoamingController(screens: [fullHD, secondary])
        rc.summon(onScreenAt: CGPoint(x: 2000, y: 500))  // on secondary
        #expect(rc.mode == .summon)
        #expect(rc.target == CGPoint(x: 1920 + 2560 / 2, y: 720))
    }

    @Test func summonFallsBackToFirstScreenWhenCursorOffscreen() {
        let rc = RoamingController(screens: [fullHD])
        rc.summon(onScreenAt: CGPoint(x: -9999, y: -9999))
        #expect(rc.mode == .summon)
        #expect(rc.target == CGPoint(x: 960, y: 540))
    }

    @Test func tickMovesPositionTowardTarget() {
        let rc = RoamingController(screens: [fullHD], initial: .zero, speed: 10)
        rc.summon(onScreenAt: .zero)            // sets mode = summon, target = (960,540)
        rc.target = CGPoint(x: 100, y: 0)       // override target for a linear test
        rc.tick(deltaTime: 1.0)
        #expect(abs(rc.position.x - 10) < 0.01)
    }

    @Test func reachesTargetWithinTolerance() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 99, y: 0), speed: 10)
        rc.summon(onScreenAt: .zero)
        rc.target = CGPoint(x: 100, y: 0)
        rc.tick(deltaTime: 1.0)
        #expect(rc.reachedTarget)
    }

    @Test func idleStopsMovement() {
        let rc = RoamingController(screens: [fullHD], initial: .zero, speed: 100)
        rc.target = CGPoint(x: 500, y: 500)
        rc.idle()
        rc.tick(deltaTime: 1.0)
        #expect(rc.position == .zero)
    }

    @Test func sleepStopsMovement() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 10, y: 10), speed: 100)
        rc.target = CGPoint(x: 500, y: 500)
        rc.sleep()
        rc.tick(deltaTime: 1.0)
        #expect(rc.position == CGPoint(x: 10, y: 10))
    }

    @Test func startStrollPicksATargetWithinScreen() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startStroll()
        #expect(rc.mode == .stroll)
        #expect(fullHD.frame.contains(rc.target))
    }

    @Test func celebrationHopsUpAndReturnsToOrigin() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startCelebration(peakHeight: 30, duration: 0.35)
        #expect(rc.mode == .celebrating)

        for _ in 0..<10 { rc.tick(deltaTime: 0.35 / 20) }   // ~0.175s in
        let midY = rc.position.y
        #expect(midY > 500 + 20, "Should be near the peak (+30) at midpoint")

        for _ in 0..<15 { rc.tick(deltaTime: 0.35 / 20) }
        #expect(rc.position == CGPoint(x: 500, y: 500))
        #expect(rc.mode != .celebrating)
    }

    @Test func celebrationDoesNotMoveX() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startCelebration(peakHeight: 30, duration: 0.35)
        for _ in 0..<25 { rc.tick(deltaTime: 0.35 / 20) }
        #expect(abs(rc.position.x - 500) < 0.01)
    }

    @Test func celebratingSuppressesStrollTarget() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startStroll()
        let strollTarget = rc.target
        rc.startCelebration(peakHeight: 10, duration: 0.1)
        rc.tick(deltaTime: 0.05)
        #expect(rc.position.x == 500)
        #expect(rc.position.y > 500)
        _ = strollTarget
    }
}
