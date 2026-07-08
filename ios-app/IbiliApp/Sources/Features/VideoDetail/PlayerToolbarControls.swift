import SwiftUI
import UIKit

/// Individual nav-bar trailing controls for the player. Split into
/// three sibling `ToolbarItem`s so SwiftUI renders them as discrete
/// circular system buttons (matching the leading back chevron) rather
/// than a single fused capsule.
///
/// Quality glyph is picked per-qn so the user can tell 1080P/4K/8K
/// apart without expanding the menu, while keeping a fixed-width icon
/// (no text inflating the toolbar item).

private struct NativeToolbarMenuItem: Identifiable {
    let id: String
    let title: String
    var systemImage: String?
    var isSelected = false
    var isEnabled = true
    let action: () -> Void

    init(id: String,
         title: String,
         systemImage: String? = nil,
         isSelected: Bool = false,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }
}

private struct NativeToolbarMenuSection: Identifiable {
    let id: String
    var title: String = ""
    var items: [NativeToolbarMenuItem]
}

private enum NativeToolbarMenuLabel {
    case systemImage(String, tint: UIColor)
    case badge(String, tint: UIColor, isActive: Bool)
}

private struct NativeToolbarMenuButton: UIViewRepresentable {
    let label: NativeToolbarMenuLabel
    let sections: [NativeToolbarMenuSection]
    var isEnabled = true
    var accessibilityLabel: String
    var onOpen: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = NativeToolbarMenuUIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = false
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleTouchDown), for: .touchDown)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        configure(button)
        button.menu = makeMenu()
        button.isEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.42
        button.accessibilityLabel = accessibilityLabel
    }

    private func configure(_ button: UIButton) {
        button.configuration = nil
        button.tintColor = label.tintColor
        button.backgroundColor = .clear
        button.layer.borderWidth = 0
        button.layer.cornerRadius = 0
        button.layer.borderColor = nil
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.setTitle(nil, for: .normal)
        button.setAttributedTitle(nil, for: .normal)
        button.setImage(nil, for: .normal)

        switch label {
        case let .systemImage(name, tint):
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            button.tintColor = tint
            button.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        case let .badge(text, tint, isActive):
            button.tintColor = tint
            button.setImage(badgeImage(text: text, tint: tint, isActive: isActive), for: .normal)
        }
    }

    private func badgeImage(text: String, tint: UIColor, isActive: Bool) -> UIImage {
        let width = max(CGFloat(25), CGFloat(text.count * 8 + 8))
        let size = CGSize(width: width, height: 18)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
            if isActive {
                tint.withAlphaComponent(0.18).setFill()
                path.fill()
            }
            tint.setStroke()
            path.lineWidth = 1.5
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .heavy),
                .foregroundColor: tint,
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2 - 0.5,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func makeMenu() -> UIMenu {
        let children: [UIMenuElement] = sections.map { section in
            UIMenu(
                title: section.title,
                options: .displayInline,
                children: section.items.map(makeAction)
            )
        }
        return UIMenu(title: "", children: children)
    }

    private func makeAction(_ item: NativeToolbarMenuItem) -> UIAction {
        var attributes = UIMenuElement.Attributes()
        if !item.isEnabled {
            attributes.insert(.disabled)
        }
        return UIAction(
            title: item.title,
            image: item.systemImage.flatMap { UIImage(systemName: $0) },
            attributes: attributes,
            state: item.isSelected ? .on : .off
        ) { _ in
            DispatchQueue.main.async {
                item.action()
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: NativeToolbarMenuButton

        init(parent: NativeToolbarMenuButton) {
            self.parent = parent
        }

        @objc func handleTouchDown() {
            parent.onOpen?()
        }
    }
}

private final class NativeToolbarMenuUIButton: UIButton {
    override var intrinsicContentSize: CGSize {
        CGSize(width: 30, height: 24)
    }
}

private extension NativeToolbarMenuLabel {
    var tintColor: UIColor {
        switch self {
        case let .systemImage(_, tint), let .badge(_, tint, _):
            return tint
        }
    }
}

struct PlayerToolbarDanmaku: View {
    @Binding var danmakuEnabled: Bool
    var isEnabled: Bool = true
    /// Long-press handler — typically opens the danmaku-send sheet.
    var onLongPress: (() -> Void)? = nil
    @State private var suppressTapAfterLongPress = false
    @State private var recognizedLongPressDuringTouch = false
    @State private var suppressTapResetWork: DispatchWorkItem?
    @GestureState private var isTouchingButton = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            if suppressTapAfterLongPress {
                clearSuppressedTap(cancelScheduledReset: true)
                return
            }
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
                    suppressTapAfterLongPress = true
                    recognizedLongPressDuringTouch = true
                    suppressTapResetWork?.cancel()
                    onLongPress?()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isTouchingButton) { _, state, _ in
                    state = true
                }
        )
        .onChange(of: isTouchingButton) { isTouching in
            guard isEnabled else { return }
            if isTouching {
                suppressTapResetWork?.cancel()
                recognizedLongPressDuringTouch = false
            } else if recognizedLongPressDuringTouch {
                scheduleSuppressedTapReset()
            }
        }
        .onDisappear {
            clearSuppressedTap(cancelScheduledReset: true)
        }
    }

    private func scheduleSuppressedTapReset() {
        suppressTapResetWork?.cancel()
        let work = DispatchWorkItem {
            clearSuppressedTap()
        }
        suppressTapResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func clearSuppressedTap(cancelScheduledReset: Bool = false) {
        if cancelScheduledReset {
            suppressTapResetWork?.cancel()
        }
        suppressTapAfterLongPress = false
        recognizedLongPressDuringTouch = false
        suppressTapResetWork = nil
    }
}

struct PlayerToolbarSubtitle: View {
    let subtitles: [VideoSubtitleDTO]
    let selectedID: String?
    var isEnabled: Bool = true
    let isLoadingID: String?
    let onPick: (VideoSubtitleDTO) -> Void
    let onDisable: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        NativeToolbarMenuButton(
            label: .badge("CC", tint: UIColor(IbiliTheme.accent), isActive: selectedID != nil),
            sections: subtitleSections,
            isEnabled: isEnabled && !subtitles.isEmpty,
            accessibilityLabel: "字幕",
            onOpen: onOpen
        )
    }

    private var subtitleSections: [NativeToolbarMenuSection] {
        guard !subtitles.isEmpty else {
            return [
                NativeToolbarMenuSection(
                    id: "empty",
                    items: [
                        NativeToolbarMenuItem(id: "empty", title: "暂无字幕", isEnabled: false) {}
                    ]
                ),
            ]
        }
        var items: [NativeToolbarMenuItem] = [
            NativeToolbarMenuItem(
                id: "off",
                title: "关闭字幕",
                isSelected: selectedID == nil,
                action: onDisable
            ),
        ]
        items.append(contentsOf: subtitles.map { item in
            let title = item.lanDoc.isEmpty ? item.lan : item.lanDoc
            return NativeToolbarMenuItem(
                id: item.id,
                title: title,
                systemImage: item.id == isLoadingID ? "arrow.clockwise" : nil,
                isSelected: item.id == selectedID
            ) {
                onPick(item)
            }
        })
        return [NativeToolbarMenuSection(id: "subtitles", items: items)]
    }
}

struct PlayerToolbarVideoQuality: View {
    let qualities: [(qn: Int64, label: String)]
    let currentQn: Int64
    let onPick: (Int64) -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        NativeToolbarMenuButton(
            label: qualityToolbarLabel(for: currentQn),
            sections: qualitySections,
            isEnabled: !qualities.isEmpty,
            accessibilityLabel: "画质",
            onOpen: onOpen
        )
    }

    private var qualitySections: [NativeToolbarMenuSection] {
        let items: [NativeToolbarMenuItem]
        if qualities.isEmpty {
            items = [
                NativeToolbarMenuItem(id: "loading", title: "正在加载", isEnabled: false) {}
            ]
        } else {
            items = qualities.map { quality in
                NativeToolbarMenuItem(
                    id: String(quality.qn),
                    title: quality.label,
                    isSelected: quality.qn == currentQn
                ) {
                    onPick(quality.qn)
                }
            }
        }
        return [NativeToolbarMenuSection(id: "qualities", items: items)]
    }

    private func qualityToolbarLabel(for qn: Int64) -> NativeToolbarMenuLabel {
        switch qn {
        case 120:
            return .systemImage("4k.tv", tint: UIColor(IbiliTheme.accent))
        case 126:
            return .badge("DV", tint: UIColor(IbiliTheme.accent), isActive: false)
        case 127:
            return .badge("8K", tint: UIColor(IbiliTheme.accent), isActive: false)
        case 125:
            return .badge("HDR", tint: UIColor(IbiliTheme.accent), isActive: false)
        case 116, 112, 80:
            return .badge("FHD", tint: UIColor(IbiliTheme.accent), isActive: false)
        case 64, 74:
            return .badge("HD", tint: UIColor(IbiliTheme.accent), isActive: false)
        case 32:
            return .badge("SD", tint: UIColor(IbiliTheme.accent), isActive: false)
        case 16, 6:
            return .badge("LD", tint: UIColor(IbiliTheme.accent), isActive: false)
        default:
            return .systemImage("tv", tint: UIColor(IbiliTheme.accent))
        }
    }
}

struct PlayerToolbarOverflowMenu: View {
    let audioQualities: [(qn: Int64, label: String)]
    let currentAudioQn: Int64
    let completionBehavior: PlayerCompletionBehavior
    var isEnabled: Bool = true
    let onPickAudioQuality: (Int64) -> Void
    let onSelectCompletionBehavior: (PlayerCompletionBehavior) -> Void
    let onOpenOfflineDownload: () -> Void
    let onOpenDanmakuStyle: () -> Void
    let onSaveCover: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        NativeToolbarMenuButton(
            label: .systemImage("ellipsis.circle", tint: .white),
            sections: overflowSections,
            isEnabled: isEnabled,
            accessibilityLabel: "更多",
            onOpen: onOpen
        )
    }

    private var overflowSections: [NativeToolbarMenuSection] {
        var sections: [NativeToolbarMenuSection] = []
        if !audioQualities.isEmpty {
            sections.append(NativeToolbarMenuSection(
                id: "audio",
                title: "音质",
                items: audioQualities.map { quality in
                    NativeToolbarMenuItem(
                        id: "audio-\(quality.qn)",
                        title: quality.label,
                        systemImage: "hifispeaker",
                        isSelected: quality.qn == currentAudioQn
                    ) {
                        onPickAudioQuality(quality.qn)
                    }
                }
            ))
        }
        sections.append(NativeToolbarMenuSection(
            id: "completion",
            title: "播放完行为",
            items: PlayerCompletionBehavior.allCases.map { behavior in
                NativeToolbarMenuItem(
                    id: "completion-\(behavior.rawValue)",
                    title: behavior.label,
                    systemImage: behavior.systemImage,
                    isSelected: behavior == completionBehavior
                ) {
                    onSelectCompletionBehavior(behavior)
                }
            }
        ))
        sections.append(NativeToolbarMenuSection(
            id: "actions",
            items: [
                NativeToolbarMenuItem(
                    id: "offline",
                    title: "离线缓存",
                    systemImage: "square.and.arrow.down",
                    action: onOpenOfflineDownload
                ),
                NativeToolbarMenuItem(
                    id: "danmakuStyle",
                    title: "弹幕样式",
                    systemImage: "textformat.size",
                    action: onOpenDanmakuStyle
                ),
                NativeToolbarMenuItem(
                    id: "saveCover",
                    title: "保存封面",
                    systemImage: "photo",
                    action: onSaveCover
                ),
            ]
        ))
        return sections
    }
}

struct PlayerToolbarAudioQuality: View {
    let audioQualities: [(qn: Int64, label: String)]
    let currentAudioQn: Int64
    let onPick: (Int64) -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        NativeToolbarMenuButton(
            label: .systemImage("hifispeaker", tint: UIColor(IbiliTheme.accent)),
            sections: audioSections,
            isEnabled: !audioQualities.isEmpty,
            accessibilityLabel: "音质",
            onOpen: onOpen
        )
    }

    private var audioSections: [NativeToolbarMenuSection] {
        let items: [NativeToolbarMenuItem]
        if audioQualities.isEmpty {
            items = [
                NativeToolbarMenuItem(id: "loading", title: "正在加载", isEnabled: false) {}
            ]
        } else {
            items = audioQualities.map { quality in
                NativeToolbarMenuItem(
                    id: String(quality.qn),
                    title: quality.label,
                    isSelected: quality.qn == currentAudioQn
                ) {
                    onPick(quality.qn)
                }
            }
        }
        return [NativeToolbarMenuSection(id: "audioQualities", items: items)]
    }
}
