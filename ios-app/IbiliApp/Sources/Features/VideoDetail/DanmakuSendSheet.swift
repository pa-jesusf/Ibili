import SwiftUI

/// Compact bottom sheet for posting a danmaku at the current playhead.
///
/// Visual: a single rounded card with the input field + 发送 button
/// on the first row, character counter + a 选项 toggle on the
/// second row, and an expandable panel below carrying mode (滚动 /
/// 顶端 / 底端) and the official-style color palette.
///
/// The progress is captured at *click time* via `progressProvider`
/// rather than at sheet-present time, so a user who scrubs after
/// opening the sheet still posts at the position they're actually
/// looking at.
struct DanmakuSendSheet: View {
    let aid: Int64
    let cid: Int64
    /// Resolves to the live playhead in milliseconds at submit time.
    let progressProvider: () -> Int64
    /// Invoked once the server has accepted the danmaku. The host
    /// typically uses this to inject a local-echo bullet into the
    /// renderer instead of refetching the full track.
    var onSent: ((DanmakuItemDTO) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var color: Int32 = 16_777_215
    @State private var mode: Int32 = 1
    @State private var isSending = false
    @State private var errorText: String?
    @State private var optionsExpanded = false
    @FocusState private var focused: Bool

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

    private let charLimit = 100

    var body: some View {
        VStack(spacing: 12) {
            CompactComposerCard(
                text: $text,
                placeholder: "发个弹幕吧…",
                charLimit: charLimit,
                isSending: isSending,
                focused: $focused,
                onSend: { Task { await send() } },
                trailing: {
                    Button {
                        optionsExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: optionsExpanded ? "chevron.down" : "slider.horizontal.3")
                                .imageScale(.small)
                            Text(optionsExpanded ? "收起" : "颜色 / 模式")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            )

            if optionsExpanded {
                optionsPanel
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                    )
            }

            if let err = errorText {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .top)
        .presentationDetents(optionsExpanded ? [.height(330)] : [.height(180)])
        .presentationDragIndicator(.visible)
        .modifier(MaterialSheetBackground())
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: optionsExpanded)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("模式")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(width: 36, alignment: .leading)
                modeButton(label: "滚动", value: 1)
                modeButton(label: "顶端", value: 5)
                modeButton(label: "底端", value: 4)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("颜色")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(width: 36, alignment: .leading)
                ForEach(palette, id: \.value) { p in
                    Button {
                        color = p.value
                    } label: {
                        Circle()
                            .fill(Color(rgb: p.value))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().stroke(
                                    color == p.value ? IbiliTheme.accent : Color.black.opacity(0.12),
                                    lineWidth: color == p.value ? 2 : 0.8
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.name)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    @ViewBuilder
    private func modeButton(label: String, value: Int32) -> some View {
        Button { mode = value } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(mode == value ? .white : IbiliTheme.textPrimary)
                .background(
                    Capsule().fill(mode == value ? IbiliTheme.accent : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private func send() async {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, msg.count <= charLimit else { return }
        // Snapshot the playhead at click time, NOT at sheet-present
        // time. Otherwise scrubbing while the sheet is open would
        // post the bullet to the wrong moment in the video.
        let progressMs = progressProvider()
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
            let echo = DanmakuItemDTO(
                timeSec: Float(Double(progressMs) / 1000.0),
                mode: mode,
                color: UInt32(bitPattern: color),
                fontSize: 25,
                text: msg,
                isSelf: true
            )
            onSent?(echo)
            dismiss()
        } catch {
            errorText = (error as NSError).localizedDescription
        }
    }
}

private extension Color {
    init(rgb: Int32) {
        let v = UInt32(bitPattern: rgb)
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

/// Apply `.presentationBackground(.regularMaterial)` only on the OS
/// versions that support it (iOS 16.4+) — older targets fall back to
/// the system default sheet background.
private struct MaterialSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(.regularMaterial)
        } else {
            content
        }
    }
}
