import SwiftUI

/// Top-right control cluster painted over the player surface. Icons
/// only — Apple HIG style — with chevron menus where multiple choices
/// are available (quality / audio quality / overflow).
///
/// Hidden in fullscreen because AVKit owns its own native chrome there.
struct PlayerOverlayControls: View {
    let qualities: [(qn: Int64, label: String)]
    let currentQn: Int64
    let audioQualities: [(qn: Int64, label: String)]
    let currentAudioQn: Int64
    @Binding var danmakuEnabled: Bool
    let onPickQuality: (Int64) -> Void
    let onPickAudioQuality: (Int64) -> Void
    /// Long-press on the danmaku toggle — usually opens the send sheet.
    var onDanmakuLongPress: (() -> Void)? = nil
    /// Pull-out actions: AirPlay route picker, AVPlayer 文章, etc.
    /// Caller decides what the overflow menu does.
    var overflowActions: [OverflowAction] = []

    struct OverflowAction: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let action: () -> Void
    }

    var body: some View {
        HStack(spacing: 10) {
            // Danmaku toggle
            IconButton(
                systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble",
                size: 36, symbolSize: 14,
                surface: .glass,
                tint: danmakuEnabled ? IbiliTheme.accent : .white
            ) { danmakuEnabled.toggle() }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in onDanmakuLongPress?() }
            )

            // Video quality menu
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
                    overlaySymbol(qualityIcon(for: currentQn))
                }
            }

            // Audio quality menu (icon-only; system shows current via menu)
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
                    overlaySymbol("hifispeaker")
                }
            }

            // Overflow
            if !overflowActions.isEmpty {
                Menu {
                    ForEach(overflowActions) { item in
                        Button {
                            item.action()
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                } label: {
                    overlaySymbol("ellipsis")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    /// SF Symbol picked to reflect the active video quality. Falls back
    /// to a neutral TV glyph when the qn is unknown.
    private func qualityIcon(for qn: Int64) -> String {
        switch qn {
        case 127: return "8k.tv"                  // 8K
        case 120, 125, 126: return "4k.tv"        // 4K / HDR / 杜比
        case 116, 112, 80: return "tv.fill"       // 1080P / 1080P+ / 1080P60
        case 64, 74: return "tv"                  // 720P / 720P60
        case 32, 16, 6: return "play.tv"          // 480P / 360P / 流畅
        default: return "tv"
        }
    }

    private func overlaySymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(
                Circle().fill(.regularMaterial)
                    .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
            )
            .contentShape(Circle())
    }
}
