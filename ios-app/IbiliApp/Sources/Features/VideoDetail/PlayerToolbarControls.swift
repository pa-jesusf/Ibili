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
    var body: some View {
        Button {
            danmakuEnabled.toggle()
        } label: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
        }
        .tint(danmakuEnabled ? IbiliTheme.accent : nil)
        .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "开启弹幕")
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
                Image(systemName: qualityIcon(for: currentQn))
            }
            .accessibilityLabel("画质")
        }
    }

    /// Distinct SF Symbol per quality bucket. 8K/4K use the dedicated
    /// resolution glyphs; 1080P/720P use the filled/outline TV pair so
    /// the gap is visible without text; SD/360P use the smaller-screen
    /// glyph so it reads as a downshift.
    private func qualityIcon(for qn: Int64) -> String {
        switch qn {
        case 127: return "8k.tv"
        case 120, 125, 126: return "4k.tv"
        case 116, 112, 80: return "tv.fill"
        case 64, 74: return "tv"
        case 32, 16, 6: return "play.tv"
        default: return "tv"
        }
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
