import Testing
@testable import CliBuddy

@Suite struct BuddyMoodTests {
    @Test func colorForEachMood() {
        #expect(BuddyMood.thinking.hexColor  == "#8B5CF6")
        #expect(BuddyMood.tooling.hexColor   == "#22D3EE")
        #expect(BuddyMood.waiting.hexColor   == "#86EFAC")
        #expect(BuddyMood.attention.hexColor == "#F59E0B")
        #expect(BuddyMood.error.hexColor     == "#EF4444")
        #expect(BuddyMood.idle.hexColor      == "#9CA3AF")
    }

    @Test func allSixMoodsEnumerated() {
        #expect(BuddyMood.allCases.count == 6)
    }
}
