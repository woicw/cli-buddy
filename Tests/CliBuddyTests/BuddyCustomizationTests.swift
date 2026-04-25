import Testing
import Foundation
@testable import CliBuddy

@Suite struct BuddyCustomizationTests {
    @Test func defaultValues() {
        let c = BuddyCustomization()
        #expect(c.pixelSize == 4)
        #expect(c.roamSpeed == .medium)
        #expect(c.crossScreenEnabled)
        #expect(c.autoBubblesEnabled)
        #expect(c.soundEnabled)
        #expect(c.paletteName == "default")
    }

    @Test func encodeDecodeRoundtrip() throws {
        let c = BuddyCustomization(
            pixelSize: 5,
            roamSpeed: .fast,
            crossScreenEnabled: false,
            autoBubblesEnabled: false,
            soundEnabled: false,
            paletteName: "neon"
        )
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(BuddyCustomization.self, from: data)
        #expect(back == c)
    }
}
