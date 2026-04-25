import Testing
import Foundation
@testable import CliBuddy

@Suite struct SessionStateTests {
    @Test func displayNameUsesCwdBasename() {
        let s = SessionState(sessionId: "abc123", cwd: "/Users/kai/woicw/cli-buddy")
        #expect(s.displayName == "cli-buddy")
    }

    @Test func displayNameFallsBackToSessionPrefix() {
        let s = SessionState(sessionId: "ses-abcdef1234567890", cwd: "")
        #expect(s.displayName == "ses-abcd")
    }

    @Test func zombieWhenOlderThanFiveMinutes() {
        let oldDate = Date(timeIntervalSinceNow: -400)
        let s = SessionState(sessionId: "x", cwd: "/x", lastEventAt: oldDate)
        #expect(s.isZombie)
    }

    @Test func notZombieWhenRecent() {
        let s = SessionState(sessionId: "x", cwd: "/x", lastEventAt: Date())
        #expect(!s.isZombie)
    }
}
