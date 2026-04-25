import SwiftUI

/// Real settings form. Read via `@EnvironmentObject CustomizationStore`
/// so mutations persist automatically (the store's didSet writes to
/// UserDefaults).
struct SettingsView: View {
    @EnvironmentObject var customization: CustomizationStore

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Species", selection: $customization.value.species) {
                    ForEach(BuddySpecies.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                Picker("Pixel size", selection: $customization.value.pixelSize) {
                    ForEach([3, 4, 5, 6, 8], id: \.self) { size in
                        Text("\(size) px").tag(size)
                    }
                }
                Picker("Palette", selection: $customization.value.paletteName) {
                    Text("Default").tag("default")
                    Text("Neon").tag("neon")
                }
            }

            Section("Behavior") {
                Toggle("Roam the desktop", isOn: $customization.value.roamingEnabled)
                Picker("Roam speed", selection: $customization.value.roamSpeed) {
                    ForEach(RoamSpeed.allCases, id: \.self) { s in
                        Text(s.rawValue.capitalized).tag(s)
                    }
                }
                .disabled(!customization.value.roamingEnabled)
                Toggle("Cross-screen roaming", isOn: $customization.value.crossScreenEnabled)
                    .disabled(!customization.value.roamingEnabled)
                Toggle("Auto-popup bubbles", isOn: $customization.value.autoBubblesEnabled)
            }

            Section("Sound") {
                Toggle("8-bit sound effects", isOn: $customization.value.soundEnabled)
            }
        }
        .padding(24)
        .frame(width: 420, height: 360)
    }
}
