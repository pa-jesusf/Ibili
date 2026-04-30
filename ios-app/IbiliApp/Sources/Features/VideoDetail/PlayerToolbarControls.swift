import SwiftUI

/// Navigation-bar trailing controls for the player. Uses plain
/// `Button` / `Menu` items so SwiftUI renders them with the same
/// system style as the leading back button.
///
/// Quality menus expose readable text labels (e.g. "1080P+", "Hi-Res")
/// rather than ambiguous tv-glyph variants — the screenshot-only
/// affordance was too easy to misread.
struct PlayerToolbarControls: View {
    let qualities: [(qn: Int64, label: String)]
    let currentQn: Int64
    let audioQualities: [(qn: Int64, label: String)]
    let currentAudioQn: Int64
    @Binding var danmakuEnabled: Bool
    let onPickQuality: (Int64) -> Void
    let onPickAudioQuality: (Int64) -> Void

    var body: some View {
        // Danmaku toggle
        Button {
            danmakuEnabled.toggle()
        } label: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
        }
        .tint(danmakuEnabled ? IbiliTheme.accent : nil)

        // Video quality
        if !qualities.isEmpty {
            Menu {
                ForEach(qualities, id: \.qn) { q in
                    Button {
                        onPickQuality(q.qn)
                    } label: {
                        if q.qn == currentQn {
                            Label(q.label, systemImage: "checkmark")
                        } else {
                            Text(q.label)
                        }
                    }
                }
            } label: {
                Text(currentQualityLabel)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
        }

        // Audio quality
        if !audioQualities.isEmpty {
            Menu {
                ForEach(audioQualities, id: \.qn) { q in
                    Button {
                        onPickAudioQuality(q.qn)
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
        }
    }

    /// Short label for the active video quality. Falls back to the
    /// first character of the upstream label so we always render
    /// *something* if the qn isn't in our table.
    private var currentQualityLabel: String {
        if let match = qualities.first(where: { $0.qn == currentQn })?.label {
            return shortQualityLabel(for: currentQn, fallback: match)
        }
        return shortQualityLabel(for: currentQn, fallback: "画质")
    }

    private func shortQualityLabel(for qn: Int64, fallback: String) -> String {
        switch qn {
        case 127: return "8K"
        case 126: return "杜比"
        case 125: return "HDR"
        case 120: return "4K"
        case 116: return "1080P60"
        case 112: return "1080P+"
        case 80:  return "1080P"
        case 74:  return "720P60"
        case 64:  return "720P"
        case 32:  return "480P"
        case 16:  return "360P"
        case 6:   return "流畅"
        default:  return fallback
        }
    }
}
