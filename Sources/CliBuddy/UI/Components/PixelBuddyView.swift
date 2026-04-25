import SwiftUI

/// Renders the chosen species as a 13×11 grid of filled SwiftUI
/// rectangles. Body pixels take the current mood color, eyes render
/// white, and accents render in the species-specific accent color
/// (dog nose, pig snout, pikachu cheeks).
struct PixelBuddyView: View {
    let species: BuddySpecies
    let mood: BuddyMood
    let pixelSize: CGFloat

    init(species: BuddySpecies = .cat, mood: BuddyMood, pixelSize: CGFloat = 4) {
        self.species = species
        self.mood = mood
        self.pixelSize = pixelSize
    }

    /// Derive the walk-cycle toggle from an absolute Date. 4 Hz cadence
    /// (0.25 s per frame) — pure function so tests don't need a clock.
    static func walkToggle(at date: Date) -> Bool {
        let quarterSeconds = Int(floor(date.timeIntervalSinceReferenceDate / 0.25))
        return quarterSeconds.isMultiple(of: 2) == false
    }

    static func frame(for mood: BuddyMood, walkToggle: Bool) -> BuddySprite.Frame {
        guard mood != .idle else { return .idle }
        return walkToggle ? .walk1 : .walk2
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let walkToggle = Self.walkToggle(at: context.date)
            let frame = Self.frame(for: mood, walkToggle: walkToggle)
            let lit = BuddySprite.keys(for: frame, species: species)
            let eyes = BuddySprite.eyeKeys(for: species)
            let accents = BuddySprite.accentKeys(for: species)
            let accentColor = Color(hex24: BuddySprite.sprite(for: species).accentColor)

            Canvas { ctx, _ in
                let body = mood.color
                for x in 0..<BuddySprite.gridW {
                    for y in 0..<BuddySprite.gridH {
                        let key = "\(x),\(y)"
                        guard lit.contains(key) else { continue }
                        let rect = CGRect(
                            x: CGFloat(x) * pixelSize,
                            y: CGFloat(y) * pixelSize,
                            width: pixelSize,
                            height: pixelSize
                        )
                        let fill: Color
                        if eyes.contains(key) {
                            fill = .white
                        } else if accents.contains(key) {
                            fill = accentColor
                        } else {
                            fill = body
                        }
                        ctx.fill(Path(rect), with: .color(fill))
                    }
                }
            }
            .frame(
                width: CGFloat(BuddySprite.gridW) * pixelSize,
                height: CGFloat(BuddySprite.gridH) * pixelSize
            )
        }
        .accessibilityLabel("cli-buddy pixel \(species.displayName), mood \(mood.rawValue)")
    }
}

private extension Color {
    init(hex24: UInt32) {
        let r = Double((hex24 >> 16) & 0xFF) / 255.0
        let g = Double((hex24 >>  8) & 0xFF) / 255.0
        let b = Double( hex24        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
