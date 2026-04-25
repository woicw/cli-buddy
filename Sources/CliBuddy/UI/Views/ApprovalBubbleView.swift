import SwiftUI

/// Auto-pops over the buddy when a Claude tool is waiting for approval.
/// Hitting Allow or Deny calls onDecision; × (or esc) calls onClose.
struct ApprovalBubbleView: View {
    let context: PermissionContext
    var onDecision: (Bool) -> Void
    var onClose: () -> Void = {}

    var body: some View {
        BubbleChrome(title: "Approval needed", onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.toolName)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(Date(), style: .time)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                }

                if let input = context.formattedInput, !input.isEmpty {
                    ScrollView {
                        Text(input)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                }

                HStack(spacing: 8) {
                    Button {
                        onDecision(false)
                    } label: {
                        Text("Deny")
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        onDecision(true)
                    } label: {
                        Text("Allow")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 360)
        }
    }
}
