import Testing
import Foundation
@testable import CliBuddy

@MainActor
@Suite struct CustomizationStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "cli-buddy-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func freshStoreHasDefaultValues() {
        let defaults = isolatedDefaults()
        let store = CustomizationStore(defaults: defaults)
        #expect(store.value.pixelSize == 4)
        #expect(store.value.roamSpeed == .medium)
    }

    @Test func mutationPersists() {
        let defaults = isolatedDefaults()
        let store1 = CustomizationStore(defaults: defaults, key: "x")
        store1.value.pixelSize = 6
        store1.value.roamSpeed = .fast

        let store2 = CustomizationStore(defaults: defaults, key: "x")
        #expect(store2.value.pixelSize == 6)
        #expect(store2.value.roamSpeed == .fast)
    }

    @Test func togglesBoolsPersist() {
        let defaults = isolatedDefaults()
        let store1 = CustomizationStore(defaults: defaults, key: "y")
        store1.value.crossScreenEnabled = false
        store1.value.soundEnabled = false

        let store2 = CustomizationStore(defaults: defaults, key: "y")
        #expect(!store2.value.crossScreenEnabled)
        #expect(!store2.value.soundEnabled)
    }
}
