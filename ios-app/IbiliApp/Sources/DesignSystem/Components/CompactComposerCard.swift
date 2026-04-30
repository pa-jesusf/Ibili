import SwiftUI

/// Reusable compact composer card.
///
/// Visual: a single rounded card hosting a multi-line input with a
/// circular 发送 capsule on the trailing side, then a footer row with
/// `count/limit` on the left and a freeform `trailing` slot on the
/// right (host-supplied — usually 选项 / 表情 / 图片 buttons). Designed
/// to be the body of bottom-sheet composers shared between 弹幕 and
/// 评论 send flows so both surfaces look and behave identically.
struct CompactComposerCard<Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    let charLimit: Int
    let isSending: Bool
    @FocusState.Binding var focused: Bool
    let onSend: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    .focused($focused)
                    .lineLimit(1...3)
                    .submitLabel(.send)
                    .onSubmit(onSend)

                sendButton
            }

            HStack(spacing: 0) {
                Text("\(text.count)/\(charLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(text.count > charLimit ? .red : IbiliTheme.textSecondary)

                Spacer(minLength: 8)

                trailing
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    @ViewBuilder
    private var sendButton: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !trimmed.isEmpty && text.count <= charLimit && !isSending

        Button(action: onSend) {
            Group {
                if isSending {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text("发送")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(canSend ? .white : IbiliTheme.textSecondary)
            .frame(width: 56, height: 32)
            .background(
                Capsule().fill(canSend ? IbiliTheme.accent : IbiliTheme.surface.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .animation(.easeOut(duration: 0.15), value: canSend)
    }
}
