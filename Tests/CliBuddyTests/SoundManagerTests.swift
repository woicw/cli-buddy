import Testing
import Foundation
import AVFAudio
@testable import CliBuddy

@Suite struct SoundManagerTests {
    /// Regression: macOS stops the AVAudioEngine on output-configuration
    /// changes (headphones plugged/unplugged, output device change, BT
    /// connect/disconnect, sleep/wake). Before the fix, SoundManager
    /// cached `engineStarted=true` and never noticed — every subsequent
    /// play scheduled on a stopped engine, went silent, and leaked the
    /// player node because completion callbacks don't fire on a stopped
    /// engine. The gate must be the engine's live `isRunning`, not a
    /// sticky boolean.
    @Test func playRestartsEngineAfterExternalStop() throws {
        let m = SoundManager.shared
        let wasMuted = m.globalMute
        m.globalMute = false
        defer { m.globalMute = wasMuted }

        m.play(.sessionStart)
        waitForEngineRunning(m.engine, timeout: 2.0)
        #expect(m.engine.isRunning, "first play should start the engine")

        m.engine.stop()
        #expect(!m.engine.isRunning, "sanity: external stop took effect")

        m.play(.sessionStart)
        waitForEngineRunning(m.engine, timeout: 2.0)
        #expect(m.engine.isRunning, "play after external stop must restart the engine")
    }

    private func waitForEngineRunning(_ engine: AVAudioEngine, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !engine.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
