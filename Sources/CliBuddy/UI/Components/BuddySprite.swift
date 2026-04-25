import Foundation

/// Species the user can pick. All species share a 13×11 face-only
/// pixel grid so silhouettes stay cohesive; differentiation comes from
/// ear shape and a per-species accent color (dog nose, pig snout,
/// pikachu cheeks).
enum BuddySpecies: String, CaseIterable, Codable, Sendable {
    case cat, dog, pig, pikachu

    var displayName: String {
        switch self {
        case .cat:     return "Cat"
        case .dog:     return "Dog"
        case .pig:     return "Pig"
        case .pikachu: return "Pikachu"
        }
    }
}

struct SpeciesSprite: Sendable {
    let idle: [(Int, Int)]
    let eyes: [(Int, Int)]
    /// Pixels painted in accentColor instead of the mood body color.
    /// They must also be present in `idle`.
    let accents: [(Int, Int)]
    let accentColor: UInt32  // 0xRRGGBB
}

enum BuddySprite {
    static let gridW = 13
    static let gridH = 11

    enum Frame: Sendable { case idle, walk1, walk2 }

    // MARK: - Lookup API

    static func sprite(for species: BuddySpecies) -> SpeciesSprite {
        switch species {
        case .cat:     return cat
        case .dog:     return dog
        case .pig:     return pig
        case .pikachu: return pikachu
        }
    }

    static func keys(for frame: Frame, species: BuddySpecies) -> Set<String> {
        let s = sprite(for: species)
        switch frame {
        case .idle:  return keyset(s.idle)
        case .walk1: return keyset(walk1(for: s.idle))
        case .walk2: return keyset(walk2(for: s.idle))
        }
    }

    static func eyeKeys(for species: BuddySpecies) -> Set<String> {
        keyset(sprite(for: species).eyes)
    }

    static func accentKeys(for species: BuddySpecies) -> Set<String> {
        keyset(sprite(for: species).accents)
    }

    // MARK: - Walk derivation (shared across species)

    /// Shift the leftmost bottom-row feet one pixel left for frame 1.
    static func walk1(for idle: [(Int, Int)]) -> [(Int, Int)] {
        idle.map { (x, y) in
            y == gridH - 1 && x < 7 ? (x - 1, y) : (x, y)
        }
    }

    /// Shift the rightmost bottom-row feet one pixel right for frame 2.
    static func walk2(for idle: [(Int, Int)]) -> [(Int, Int)] {
        idle.map { (x, y) in
            y == gridH - 1 && x >= 7 ? (x + 1, y) : (x, y)
        }
    }

    private static func keyset(_ pixels: [(Int, Int)]) -> Set<String> {
        Set(pixels.map { "\($0.0),\($0.1)" })
    }

    // MARK: - Cat (triangular ears, tapered cheeks)

    static let cat: SpeciesSprite = {
        var pixels: [(Int, Int)] = []
        // Rows 1-2 — tall triangular ears
        pixels += [(2, 1), (10, 1)]
        pixels += [(1, 2), (2, 2), (3, 2), (9, 2), (10, 2), (11, 2)]
        // Row 3 — head top (ears merge into forehead)
        pixels += (1...11).map { ($0, 3) }
        // Rows 4-5 — widest cheeks (eyes on row 5)
        pixels += (0...12).map { ($0, 4) }
        pixels += (0...12).map { ($0, 5) }
        // Rows 6-7 — head tapers below the eyes
        pixels += (1...11).map { ($0, 6) }
        pixels += (1...11).map { ($0, 7) }
        // Rows 8-9 — muzzle narrows
        pixels += (2...10).map { ($0, 8) }
        pixels += (2...10).map { ($0, 9) }
        // Row 10 — feet block (drives the walk animation)
        pixels += (3...9).map { ($0, 10) }
        return SpeciesSprite(
            idle: pixels,
            eyes: [(3, 5), (9, 5)],
            accents: [],
            accentColor: 0xFFFFFF
        )
    }()

    // MARK: - Dog (floppy ears + dark nose)

    static let dog: SpeciesSprite = {
        var pixels: [(Int, Int)] = []
        // Rows 1-2 — floppy ears hanging off the sides
        pixels += [(1, 1), (2, 1), (10, 1), (11, 1)]
        pixels += [(0, 2), (1, 2), (2, 2), (3, 2),
                   (9, 2), (10, 2), (11, 2), (12, 2)]
        // Row 3 — head top merges with ears
        pixels += (0...12).map { ($0, 3) }
        // Row 4 — head
        pixels += (1...11).map { ($0, 4) }
        // Row 5 — eyes row
        pixels += (1...11).map { ($0, 5) }
        // Row 6 — head continues
        pixels += (1...11).map { ($0, 6) }
        // Row 7 — muzzle starts narrower
        pixels += (2...10).map { ($0, 7) }
        // Row 8 — muzzle
        pixels += (3...9).map { ($0, 8) }
        // Row 9 — muzzle tip
        pixels += (4...8).map { ($0, 9) }
        // Row 10 — nose (accent color below)
        pixels += (5...7).map { ($0, 10) }
        return SpeciesSprite(
            idle: pixels,
            eyes: [(3, 5), (9, 5)],
            accents: [(5, 10), (6, 10), (7, 10)],
            accentColor: 0x1F2937  // near-black nose
        )
    }()

    // MARK: - Pig (tiny triangular ears + pink snout)

    static let pig: SpeciesSprite = {
        var pixels: [(Int, Int)] = []
        // Rows 1-2 — tiny triangle ears tucked against head
        pixels += [(2, 1), (10, 1)]
        pixels += [(1, 2), (2, 2), (3, 2), (9, 2), (10, 2), (11, 2)]
        // Rows 3-4 — round head top
        pixels += (1...11).map { ($0, 3) }
        pixels += (0...12).map { ($0, 4) }
        // Row 5 — eyes row, widest (piggy cheeks)
        pixels += (0...12).map { ($0, 5) }
        // Rows 6-7 — head continues
        pixels += (0...12).map { ($0, 6) }
        pixels += (1...11).map { ($0, 7) }
        // Row 8 — snout begins (centered)
        pixels += (3...9).map { ($0, 8) }
        // Row 9 — snout (accent band)
        pixels += (3...9).map { ($0, 9) }
        // Row 10 — snout bottom (accent)
        pixels += (4...8).map { ($0, 10) }
        return SpeciesSprite(
            idle: pixels,
            eyes: [(3, 5), (9, 5)],
            // Pink snout disc: bottom three rows in the center
            accents: [
                (3, 8), (4, 8), (5, 8), (6, 8), (7, 8), (8, 8), (9, 8),
                (3, 9), (4, 9), (5, 9), (6, 9), (7, 9), (8, 9), (9, 9),
                (4, 10), (5, 10), (6, 10), (7, 10), (8, 10),
            ],
            accentColor: 0xF472B6
        )
    }()

    // MARK: - Pikachu (tall thin ears + red cheeks)

    static let pikachu: SpeciesSprite = {
        var pixels: [(Int, Int)] = []
        // Rows 0-1 — thin tall ears (1 pixel wide at top)
        pixels += [(2, 0), (10, 0)]
        pixels += [(2, 1), (10, 1)]
        // Row 2 — ears widen slightly into head
        pixels += [(1, 2), (2, 2), (3, 2), (9, 2), (10, 2), (11, 2)]
        // Rows 3-4 — head top
        pixels += (1...11).map { ($0, 3) }
        pixels += (0...12).map { ($0, 4) }
        // Row 5 — eyes row, widest
        pixels += (0...12).map { ($0, 5) }
        // Row 6 — cheeks row (accent at edges)
        pixels += (0...12).map { ($0, 6) }
        // Row 7 — head continues
        pixels += (0...12).map { ($0, 7) }
        // Row 8 — lower face
        pixels += (1...11).map { ($0, 8) }
        // Row 9 — chin
        pixels += (2...10).map { ($0, 9) }
        // Row 10 — bottom
        pixels += (3...9).map { ($0, 10) }
        return SpeciesSprite(
            idle: pixels,
            eyes: [(3, 5), (9, 5)],
            // Red cheeks in the lower-eye corners
            accents: [(1, 6), (11, 6)],
            accentColor: 0xEF4444
        )
    }()
}
