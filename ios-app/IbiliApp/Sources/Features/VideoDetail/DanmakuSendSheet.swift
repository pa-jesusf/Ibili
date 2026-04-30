import SwiftUI

/// Bottom sheet for composing and posting a danmaku at the current
/// playhead. Color + mode (滚动 / 顶端 / 底端) selectable; submit calls
/// `CoreClient.sendDanmaku` and dismisses on success. Shows an inline
/// error and keeps the text on failure so the user can retry.
struct DanmakuSendSheet: View {
    let aid: Int64
    let cid: Int64
    /// Current playhead in milliseconds, captured at present time.
    let progressMs: Int64

    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var color: Int32 = 16_777_215
    @State private var mode: Int32 = 1
    @State private var isSending = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    /// Bilibili's "official" preset palette (subset). Keeps the sheet
    /// compact — power users can extend later.
    private let palette: [(name: String, value: Int32)] = [
        ("白", 16_777_215),
        ("红", 16_711_680),
        ("橙", 16_744_192),
        ("黄", 16_776_960),
        ("绿", 65_280),
        ("青", 65_535),
        ("蓝", 4_607_999),
        ("紫", 10_233_776),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("发送一条友善的弹幕", text: $text, axis: .vertical)
                    .font(.body)
                    .focused($focused)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IbiliTheme.surface))

                Text("位置 · \(BiliFormat.duration(Int64(progressMs / 1000)))")
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("模式").font(.caption.weight(.medium)).foregroundStyle(IbiliTheme.textSecondary)
                    HStack(spacing: 8) {
                        modeButton(label: "滚动", value: 1)
                        modeButton(label: "顶端", value: 5)
                        modeButton(label: "底端", value: 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("颜色").font(.caption.weight(.medium)).foregroundStyle(IbiliTheme.textSecondary)
                    HStack(spacing: 10) {
                        ForEach(palette, id: \.value) { p in
                            Button {
                                color = p.value
                            } label: {
                                Circle()
                                    .fill(Color(rgb: p.value))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle().stroke(
                                            color == p.value ? IbiliTheme.accent : Color.black.opacity(0.1),
                                            lineWidth: color == p.value ? 2.5 : 1
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(p.name)
                        }
                    }
                }

                if let err = errorText {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle("发送弹幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("发送").fontWeight(.semibold)
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func modeButton(label: String, value: Int32) -> some View {
        Button { mode = value } label: {
            Text(label)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(mode == value ? .white : IbiliTheme.textPrimary)
                .background(
                    Capsule().fill(mode == value ? IbiliTheme.accent : IbiliTheme.surface)
                )
        }
        .buttonStyle(.plain)
    }

    private func send() async {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        isSending = true
        errorText = nil
        defer { isSending = false }
        do {
            try await Task.detached(priority: .userInitiated) { [aid, cid, msg, progressMs, mode, color] in
                try CoreClient.shared.sendDanmaku(
                    aid: aid, cid: cid, msg: msg,
                    progressMs: progressMs, mode: mode, color: color
                )
            }.value
            dismiss()
        } catch {
            errorText = (error as NSError).localizedDescription
        }
    }
}

private extension Color {
    /// Decode a packed RGB integer (Bilibili wire format) into a SwiftUI
    /// Color. `#RRGGBB` semantics — top byte ignored.
    init(rgb: Int32) {
        let v = UInt32(bitPattern: rgb)
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
