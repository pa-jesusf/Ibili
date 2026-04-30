import SwiftUI

/// Individual nav-bar trailing controls for the player. Split into
/// three sibling `ToolbarItem`s so SwiftUI renders them as discrete
/// circular system buttons (matching the leading back chevron) rather
/// than a single fused capsule.
///
/// Quality glyph is picked per-qn so the user can tell 1080P/4K/8K
/// apart without expanding the menu, while keeping a fixed-width icon
/// (no text inflating the toolbar item).

struct PlayerToolbarDanmaku: View {
    @Binding var danmakuEnabled: Bool
    /// Long-press handler — typically opens the danmaku-send sheet.
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Button {
            danmakuEnabled.toggle()
        } label: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
        }
        .tint(danmakuEnabled ? IbiliTheme.accent : nil)
        .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "开启弹幕")
        .accessibilityHint("长按发送弹幕")
        // Toolbar items can't easily host both a tap-Button and a
        // long-press gesture, but `simultaneousGesture` works with the
        // standard Button machinery on iOS 16+.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    onLongPress?()
                }
        )
    }
}

struct PlayerToolbarVideoQuality: View {
    let qualities: [(qn: Int64, label: String)]
    let currentQn: Int64
    let onPick: (Int64) -> Void

    var body: some View {
        if qualities.isEmpty {
            EmptyView()
        } else {
            Menu {
                ForEach(qualities, id: \.qn) { q in
                    Button {
                        onPick(q.qn)
                    } label: {
                        if q.qn == currentQn {
                            Label(q.label, systemImage: "checkmark")
                        } else {
                            Text(q.label)
                        }
                    }
                }
            } label: {
                qualityIconView(for: currentQn)
            }
            .accessibilityLabel("画质")
        }
    }

    /// Toolbar glyph for the current quality. SF Symbols ships
    /// dedicated `8k.tv` / `4k.tv` icons that read instantly. For
    /// 1080P / 720P / 480P / 360P the resolution-bearing symbols
    /// either don't exist or look identical at toolbar size, so we
    /// hand-draw a tiny rounded rectangle with the canonical Bilibili
    /// shorthand (FHD/HD/SD/LD) inside — fixed-width, won't stretch
    /// the toolbar item, and tells the user the picked tier at a
    /// glance without expanding the menu.
    @ViewBuilder
    private func qualityIconView(for qn: Int64) -> some View {
        switch qn {
        case 127: Image(systemName: "8k.tv")
        case 120, 125, 126: Image(systemName: "4k.tv")
        case 116, 112, 80: QualityBadge(text: "FHD")
        case 64, 74:        QualityBadge(text: "HD")
        case 32:            QualityBadge(text: "SD")
        case 16, 6:         QualityBadge(text: "LD")
        default:            Image(systemName: "tv")
        }
    }
}

/// Lightweight 28x18 badge that mimics the visual weight of an SF
/// Symbol toolbar glyph but renders short text inside a rounded
/// outline. Avoids the toolbar-stretching that a free-floating
/// `Text("1080P+")` causes.
private struct QualityBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospaced()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 3)
            .frame(width: 28, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(lineWidth: 1.6)
            )
    }
}

struct PlayerToolbarAudioQuality: View {
    let audioQualities: [(qn: Int64, label: String)]
    let currentAudioQn: Int64
    let onPick: (Int64) -> Void

    var body: some View {
        if audioQualities.isEmpty {
            EmptyView()
        } else {
            Menu {
                ForEach(audioQualities, id: \.qn) { q in
                    Button {
                        onPick(q.qn)
                    } label: {
                        if q.qn == currentAudioQn {
                            Label(q.label, systemImage: "checkmark")
                        } else {
                            Text(q.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "hifispeaker")
            }
            .accessibilityLabel("音质")
        }
    }
}
