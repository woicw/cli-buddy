import SwiftUI

/// Shared visual chrome for every cli-buddy bubble (approval / question
/// / session list). Black-on-white-ish, high contrast, heavy corner
/// radius, top-right close button.
struct BubbleChrome<Content: View>: View {
    let title: String
    var onClose: () -> Void = {}
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .textCase(.uppercase)
                    .tracking(1.2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle().fill(.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        .foregroundStyle(.white)
        .colorScheme(.dark)
    }
}
