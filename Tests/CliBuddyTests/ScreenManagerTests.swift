import Testing
import AppKit
@testable import CliBuddy

@MainActor
@Suite struct ScreenManagerTests {
    /// Any machine running the test harness has at least one physical
    /// or virtual display, so `screens` should never be empty after
    /// `refresh()` in `init`.
    @Test func refreshesFromNSScreenOnInit() {
        let sm = ScreenManager()
        #expect(!sm.screens.isEmpty)
    }

    @Test func screenFramesMatchNSScreen() {
        let sm = ScreenManager()
        #expect(sm.screens.count == NSScreen.screens.count)
        for (i, screen) in NSScreen.screens.enumerated() {
            #expect(sm.screens[i].frame == screen.frame)
        }
    }
}
