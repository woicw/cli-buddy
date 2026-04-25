import Foundation
import Combine

/// Persists `BuddyCustomization` to `UserDefaults` and publishes changes
/// so views stay in sync. Writes happen on every property change.
@MainActor
final class CustomizationStore: ObservableObject {
    @Published var value: BuddyCustomization {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "cli-buddy.customization"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(BuddyCustomization.self, from: data) {
            self.value = decoded
        } else {
            self.value = BuddyCustomization()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
