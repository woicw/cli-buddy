import Foundation
import Testing
@testable import CliBuddy

@Suite struct PixelBuddyFrameTests {
    @Test func idleMoodUsesIdleFrame() {
        #expect(PixelBuddyView.frame(for: .idle, walkToggle: false) == .idle)
        #expect(PixelBuddyView.frame(for: .idle, walkToggle: true) == .idle)
    }

    @Test func nonIdleMoodAlternatesFrames() {
        #expect(PixelBuddyView.frame(for: .thinking, walkToggle: true) == .walk1)
        #expect(PixelBuddyView.frame(for: .thinking, walkToggle: false) == .walk2)
    }

    @Test func walkToggleFromDateIsPeriodicAt4Hz() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.25)
        let toggle0 = PixelBuddyView.walkToggle(at: t0)
        let toggle1 = PixelBuddyView.walkToggle(at: t1)
        #expect(toggle0 != toggle1)
    }

    @Test func walkToggleFromDateIsStableWithinFrame() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.05)
        #expect(PixelBuddyView.walkToggle(at: t0) == PixelBuddyView.walkToggle(at: t1))
    }

    @Test func walkToggleIsStableWithinNegativeFrame() {
        // -0.5 and -0.4 are in the same quarter-second slot per floor
        // semantics. Int() truncation put them in different slots.
        let t0 = Date(timeIntervalSinceReferenceDate: -0.5)
        let t1 = Date(timeIntervalSinceReferenceDate: -0.4)
        #expect(PixelBuddyView.walkToggle(at: t0) == PixelBuddyView.walkToggle(at: t1))
    }
}
