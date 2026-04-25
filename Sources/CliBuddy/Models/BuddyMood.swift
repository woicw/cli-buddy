import SwiftUI

enum BuddyMood: String, CaseIterable, Sendable {
    case thinking, tooling, waiting, attention, error, idle

    var hexColor: String {
        switch self {
        case .thinking:  return "#8B5CF6"
        case .tooling:   return "#22D3EE"
        case .waiting:   return "#86EFAC"
        case .attention: return "#F59E0B"
        case .error:     return "#EF4444"
        case .idle:      return "#9CA3AF"
        }
    }

    var color: Color { Color(buddyHex: hexColor) }
}

extension Color {
    init(buddyHex: String) {
        let s = buddyHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
