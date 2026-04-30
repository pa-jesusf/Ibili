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
                    overlaySymbol("4k.tv")
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
        .padding(8)
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
