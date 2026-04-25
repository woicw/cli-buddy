import Testing
@testable import CliBuddy

@Suite struct BuddySpriteTests {
    @Test func gridDimensionsAre13x11() {
        #expect(BuddySprite.gridW == 13)
        #expect(BuddySprite.gridH == 11)
    }

    @Test func eyePixelsAreLitForEverySpecies() {
        for species in BuddySpecies.allCases {
            let sprite = BuddySprite.sprite(for: species)
            let idleKeys = Set(sprite.idle.map { "\($0.0),\($0.1)" })
            for (x, y) in sprite.eyes {
                #expect(idleKeys.contains("\(x),\(y)"),
                        "\(species): eye (\(x),\(y)) missing from idle body")
            }
        }
    }

    @Test func accentPixelsAreLitForEverySpecies() {
        for species in BuddySpecies.allCases {
            let sprite = BuddySprite.sprite(for: species)
            let idleKeys = Set(sprite.idle.map { "\($0.0),\($0.1)" })
            for (x, y) in sprite.accents {
                #expect(idleKeys.contains("\(x),\(y)"),
                        "\(species): accent (\(x),\(y)) missing from idle body")
            }
        }
    }

    @Test func allLitPixelsAreInsideGridForEverySpecies() {
        for species in BuddySpecies.allCases {
            let sprite = BuddySprite.sprite(for: species)
            for (x, y) in sprite.idle {
                #expect(x >= 0 && x < BuddySprite.gridW)
                #expect(y >= 0 && y < BuddySprite.gridH)
            }
        }
    }

    @Test func allSpeciesHaveAtLeastFortyPixels() {
        for species in BuddySpecies.allCases {
            #expect(BuddySprite.sprite(for: species).idle.count >= 40,
                    "\(species) has too few pixels")
        }
    }

    @Test func walkFramesHaveSameCountAsIdle() {
        for species in BuddySpecies.allCases {
            let sprite = BuddySprite.sprite(for: species)
            let walk1 = BuddySprite.walk1(for: sprite.idle)
            let walk2 = BuddySprite.walk2(for: sprite.idle)
            #expect(walk1.count == sprite.idle.count)
            #expect(walk2.count == sprite.idle.count)
        }
    }
}
