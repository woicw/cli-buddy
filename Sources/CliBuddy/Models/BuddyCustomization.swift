import Foundation

enum RoamSpeed: String, Codable, CaseIterable, Sendable {
    case slow, medium, fast
}

struct BuddyCustomization: Codable, Equatable, Sendable {
    var species: BuddySpecies = .cat
    var pixelSize: Int = 4
    var roamingEnabled: Bool = true
    var roamSpeed: RoamSpeed = .medium
    var crossScreenEnabled: Bool = true
    var autoBubblesEnabled: Bool = true
    var soundEnabled: Bool = true
    var paletteName: String = "default"

    // MARK: - Decoding (backward-compatible for upgraded users)

    enum CodingKeys: String, CodingKey {
        case species, pixelSize, roamingEnabled, roamSpeed,
             crossScreenEnabled, autoBubblesEnabled, soundEnabled, paletteName
    }

    init(
        species: BuddySpecies = .cat,
        pixelSize: Int = 4,
        roamingEnabled: Bool = true,
        roamSpeed: RoamSpeed = .medium,
        crossScreenEnabled: Bool = true,
        autoBubblesEnabled: Bool = true,
        soundEnabled: Bool = true,
        paletteName: String = "default"
    ) {
        self.species = species
        self.pixelSize = pixelSize
        self.roamingEnabled = roamingEnabled
        self.roamSpeed = roamSpeed
        self.crossScreenEnabled = crossScreenEnabled
        self.autoBubblesEnabled = autoBubblesEnabled
        self.soundEnabled = soundEnabled
        self.paletteName = paletteName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        species = try c.decodeIfPresent(BuddySpecies.self, forKey: .species) ?? .cat
        pixelSize = try c.decodeIfPresent(Int.self, forKey: .pixelSize) ?? 4
        roamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .roamingEnabled) ?? true
        roamSpeed = try c.decodeIfPresent(RoamSpeed.self, forKey: .roamSpeed) ?? .medium
        crossScreenEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossScreenEnabled) ?? true
        autoBubblesEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoBubblesEnabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        paletteName = try c.decodeIfPresent(String.self, forKey: .paletteName) ?? "default"
    }
}
