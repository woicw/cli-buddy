import SwiftUI

/// Renders an AskUserQuestion item as a row of chip buttons plus an
/// optional free-text field. The user's answer(s) are passed back via
/// onAnswer; × / Skip calls onDismiss.
struct QuestionBubbleView: View {
    let questions: [QuestionItem]
    var onAnswer: ([String]) -> Void
    var onDismiss: () -> Void

    @State private var custom: String = ""
    @State private var picked: Set<String> = []

    var body: some View {
        BubbleChrome(title: "Question", onClose: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                if let q = questions.first {
                    if let header = q.header, !header.isEmpty {
                        Text(header)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text(q.question)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    ChipFlowLayout(spacing: 6) {
                        ForEach(q.options, id: \.label) { opt in
                            chipButton(for: opt, multi: q.multiSelect)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Custom…", text: $custom)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .onSubmit(sendCustom)
                        Button("Send") { sendCustom() }
                            .buttonStyle(.borderedProminent)
                            .tint(.white.opacity(0.22))
                            .disabled(custom.isEmpty)
                    }

                    if q.multiSelect {
                        HStack {
                            Spacer()
                            Button("Submit") { submitPicks() }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .disabled(picked.isEmpty)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
            .frame(width: 360)
        }
    }

    @ViewBuilder
    private func chipButton(for opt: QuestionOption, multi: Bool) -> some View {
        Button {
            if multi {
                if picked.contains(opt.label) {
                    picked.remove(opt.label)
                } else {
                    picked.insert(opt.label)
                }
            } else {
                onAnswer([opt.label])
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(opt.label)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(picked.contains(opt.label) ? .semibold : .regular)
                    .foregroundStyle(.white)
                if let desc = opt.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    picked.contains(opt.label)
                        ? Color.accentColor.opacity(0.28)
                        : Color.white.opacity(0.07)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    picked.contains(opt.label)
                        ? Color.accentColor.opacity(0.7)
                        : Color.white.opacity(0.12),
                    lineWidth: 0.5
                )
        )
    }

    private func sendCustom() {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer([trimmed])
    }

    private func submitPicks() {
        guard !picked.isEmpty else { return }
        onAnswer(Array(picked))
    }
}
