import SwiftUI

/// SwiftUI host for the pixel buddy. Drag is handled at the NSPanel
/// level (BuddyWindow.mouseDown → performDrag), so this view only
/// wires hover + right-click-menu. Left-click is detected by the
/// window's mouseUp comparing start/end origins.
struct BuddyHostView: View {
    static func topOverlayPadding(for pixelSize: CGFloat) -> CGFloat {
        max(24, pixelSize * 8.5)
    }

    @EnvironmentObject var brain: BuddyBrain
    @EnvironmentObject var customization: CustomizationStore
    @EnvironmentObject var workingFeedback: WorkingFeedbackController

    var onHoverChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let pixelSize = CGFloat(customization.value.pixelSize)
        let topReserve = Self.topOverlayPadding(for: pixelSize)

        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Color.clear
                        .frame(height: topReserve)

                    if let message = workingFeedback.currentMessage {
                        WorkingMessageView(text: message)
                            .offset(y: pixelSize * 0.2)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }

                ZStack(alignment: .topTrailing) {
                    PixelBuddyView(
                        species: customization.value.species,
                        mood: brain.displayMood,
                        pixelSize: pixelSize
                    )
                    .offset(y: workingFeedback.bobOffset(at: context.date))

                    if workingFeedback.showSweat {
                        SweatDropView(pixelSize: pixelSize)
                            .offset(
                                x: pixelSize * 2.4,
                                y: -pixelSize * 1.2
                            )
                            .transition(.opacity)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
    }
}

private struct SweatDropView: View {
    let pixelSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.95))
                .frame(width: pixelSize, height: pixelSize)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: pixelSize, height: pixelSize)
                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: pixelSize, height: pixelSize)
            }
        }
        .shadow(color: .white.opacity(0.35), radius: 2)
    }
}

private struct WorkingMessageView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}
