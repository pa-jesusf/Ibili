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
    var isEnabled: Bool = true
    /// Long-press handler — typically opens the danmaku-send sheet.
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Button {
            guard isEnabled else { return }
            danmakuEnabled.toggle()
        } label: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                .foregroundStyle(danmakuEnabled ? IbiliTheme.accent : .white)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .tint(danmakuEnabled ? IbiliTheme.accent : .white)
        .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "开启弹幕")
        .accessibilityHint("长按发送弹幕")
        // Toolbar items can't easily host both a tap-Button and a
        // long-press gesture, but `simultaneousGesture` works with the
        // standard Button machinery on iOS 16+.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    guard isEnabled else { return }
                    onLongPress?()
                }
        )
    }
}

struct PlayerToolbarSubtitle: View {
    let subtitles: [VideoSubtitleDTO]
    let selectedID: String?
    var isEnabled: Bool = true
    let isLoadingID: String?
    let onPick: (VideoSubtitleDTO) -> Void
    let onDisable: () -> Void

    var body: some View {
        Menu {
            if subtitles.isEmpty {
                Text("暂无字幕")
            } else {
                Button {
                    onDisable()
                } label: {
                    if selectedID == nil {
                        Label("关闭字幕", systemImage: "checkmark")
                    } else {
                        Text("关闭字幕")
                    }
                }
                ForEach(subtitles) { item in
                    Button {
                        onPick(item)
                    } label: {
                        let title = item.lanDoc.isEmpty ? item.lan : item.lanDoc
                        if item.id == selectedID {
                            Label(title, systemImage: "checkmark")
                        } else if item.id == isLoadingID {
                            Label(title, systemImage: "arrow.clockwise")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        } label: {
            PlayerToolbarCCIcon(isActive: selectedID != nil)
        }
        .disabled(!isEnabled || subtitles.isEmpty)
        .opacity(isEnabled && !subtitles.isEmpty ? 1 : 0.42)
        .tint(IbiliTheme.accent)
        .accessibilityLabel("字幕")
    }
}

private struct PlayerToolbarCCIcon: View {
    let isActive: Bool

    var body: some View {
        Text("CC")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospaced()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(IbiliTheme.accent)
            .frame(width: 25, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? IbiliTheme.accent.opacity(0.18) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(IbiliTheme.accent, lineWidth: 1.5)
            }
    }
}

struct PlayerToolbarVideoQuality: View {
    let qualities: [(qn: Int64, label: String)]
    let currentQn: Int64
    let onPick: (Int64) -> Void

    var body: some View {
        Menu {
            if qualities.isEmpty {
                Text("正在加载")
            } else {
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
            }
        } label: {
            qualityIconView(for: currentQn)
        }
        .disabled(qualities.isEmpty)
        .opacity(qualities.isEmpty ? 0.42 : 1)
        .tint(IbiliTheme.accent)
        .accessibilityLabel("画质")
    }

    /// Toolbar glyph for the current quality. SF Symbols ships
    /// dedicated `8k.tv` / `4k.tv` icons that read instantly. The
    /// premium tiers (HDR / Dolby Vision) share their pixel count
    /// with 4K but mean very different things to the user, so each
    /// gets its own visual:
    /// * 8K     → `8k.tv`
    /// * 4K     → `4k.tv`
    /// * 4K HDR → 4k.tv with a small "HDR" pill stacked on top, so
    ///            the resolution glyph reads first and the HDR-ness
    ///            is unambiguous.
    /// * 杜比视界 → the iconic Dolby double-D mark, hand-drawn so we
    ///            don't ship an asset.
    /// 1080P / 720P / 480P / 360P fall back to the FHD/HD/SD/LD
    /// rounded-rect badge (resolution SF Symbols don't exist below
    /// 4k.tv).
    @ViewBuilder
    private func qualityIconView(for qn: Int64) -> some View {
        switch qn {
        case 127: QualityBadge(text: "8K")
        case 120: Image(systemName: "4k.tv")
        case 125: QualityBadge(text: "HDR")
        case 126: DolbyVisionIcon()
        case 116, 112, 80: QualityBadge(text: "FHD")
        case 64, 74:        QualityBadge(text: "HD")
        case 32:            QualityBadge(text: "SD")
        case 16, 6:         QualityBadge(text: "LD")
        default:            Image(systemName: "tv")
        }
    }
}

/// Hand-drawn Dolby Vision mark — two opposing capital "D" silhouettes
/// forming the iconic double-D logo. Drawn from `Path` so we don't
/// have to ship a bitmap asset and the mark scales with the toolbar
/// font weight automatically. Uses the toolbar tint (accent color) so
/// it visually matches the other quality glyphs instead of rendering
/// as plain white.
private struct DolbyVisionIcon: View {
    var body: some View {
        DolbyLogoMark()
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            .foregroundStyle(.tint)
            .frame(width: 26, height: 18)
            .accessibilityLabel("杜比视界")
    }
}

private struct DolbyLogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        // The mark is two mirrored "D" half-shapes inscribed in a
        // rounded rectangle, with their flat backs meeting in the
        // middle. We draw them as two closed sub-paths so callers can
        // either stroke or fill the result and get a recognizable
        // double-D silhouette either way.
        var path = Path()
        let r = min(rect.height / 2, rect.width / 4)

        // Left D — flat side on the right, curve on the left.
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.midY),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()

        // Right D — mirrored: flat side on the left, curve on the right.
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.midY),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()

        return path
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
        Menu {
            if audioQualities.isEmpty {
                Text("正在加载")
            } else {
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
            }
        } label: {
            Image(systemName: "hifispeaker")
        }
        .disabled(audioQualities.isEmpty)
        .opacity(audioQualities.isEmpty ? 0.42 : 1)
        .tint(IbiliTheme.accent)
        .accessibilityLabel("音质")
    }
}
