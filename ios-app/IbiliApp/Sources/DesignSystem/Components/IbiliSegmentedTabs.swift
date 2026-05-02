import SwiftUI

/// Project-wide pill-style segmented control. The selected segment
/// floats inside a tinted accent capsule and renders its label in
/// `IbiliTheme.accent` (the brand pink); unselected segments are
/// plain secondary-weight text.
///
/// Used by:
///   • `VideoDetailContent` — 简介 / 评论 / 相关
///   • `UserSpaceView`     — 动态 / 投稿
///
/// Both surfaces previously had their own divergent looks (a stock
/// `Picker(.segmented)` on one side, a white-on-pink pill on the
/// other). Unifying them under a single component keeps the visual
/// language consistent and gives us one place to retune the
/// "Apple-aesthetic + brand pink" balance.
struct IbiliSegmentedTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let isSelected = (tab == selection)
                Button {
                    if !isSelected {
                        // 0.28s spring matches Apple's tab-switch
                        // cadence — fast enough to feel responsive,
                        // slow enough that the indicator's slide is
                        // legible at 120Hz.
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selection = tab
                        }
                    }
                } label: {
                    Text(title(tab))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                        .background {
                            if isSelected {
                                // Soft accent fill — same pink, much
                                // lower opacity, so the pill is felt
                                // rather than shouted.
                                Capsule()
                                    .fill(IbiliTheme.accent.opacity(0.16))
                                    .matchedGeometryEffect(id: "ibili.segmented.pill", in: pill)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            // Outer container: thin glass on iOS 26+, regularMaterial
            // pre-26. Mirrors `GlassCapsuleModifier` so the surface
            // language is identical across pages without having to
            // import that file (it's intentionally fileprivate).
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
            } else {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}

struct NavigationTrailingSegmentedControl<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab
    /// Retained for source compatibility with existing call sites.
    /// The control now lives inside the navigation bar's trailing
    /// toolbar slot, so it no longer needs to react to scroll
    /// collapse — the system bar already handles all of that.
    var collapseProgress: CGFloat = 0

    private let controlWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    guard !isSelected else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selection = tab
                    }
                } label: {
                    Text(title(tab))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textPrimary.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(NavSegmentPressButtonStyle())
            }
        }
        .frame(width: controlWidth)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .modifier(NavigationGlassCapsuleModifier())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// Per-segment press feedback. Using a `ButtonStyle` keeps the tap
/// gesture wired through `Button` (so the control stays clickable)
/// and gives us a localised press animation that feels close to the
/// system navigation-bar long-press pop without consuming taps the
/// way a top-level `simultaneousGesture` does.
private struct NavSegmentPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.06 : 1, anchor: .center)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

struct ScrollHeaderOffsetReader: View {
    let coordinateSpace: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: ScrollHeaderOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named(coordinateSpace)).minY
                )
        }
        .frame(height: 0)
    }
}

struct ScrollHeaderOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NavigationGlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Capsule().fill(.regularMaterial))
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule().fill(.regularMaterial)
                        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
                )
        }
    }
}

/// Floating segmented control overlaid on top of a feed page that
/// keeps the system's native large-title navigation bar.
///
/// At rest (`collapseProgress == 0`) the capsule sits on the same row
/// as the large title, hugging the trailing edge. As the user scrolls
/// and the large title collapses into the inline navigation bar, the
/// capsule slides upward in lock-step until it lines up with the
/// inline-title row. The overlay never adds layout to the feed; it
/// purely floats over the navigation chrome.
struct FloatingNavSegmentedControl<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab
    /// 0 → fully expanded (large title visible).
    /// 1 → fully collapsed (inline title only).
    let collapseProgress: CGFloat

    var body: some View {
        let p = min(1, max(0, collapseProgress))
        // `HomeView` / `DynamicFeedView` overlay this control over the
        // content view, whose local top edge already sits *below* the
        // large-title row. The earlier `padding(.top, 52)` therefore
        // counted that 52pt row twice and dropped the capsule too low.
        // Drive the visual position with a negative offset instead:
        //   - expanded: sit back up on the large-title row
        //   - collapsed: continue travelling into the inline bar row
        // The 48pt travel mirrors the system large-title collapse.
        let expandedOffsetY: CGFloat = -48
        let collapseTravel: CGFloat = 48

        NavigationTrailingSegmentedControl(
            tabs: tabs,
            title: title,
            selection: $selection
        )
        .padding(.trailing, 16)
        .offset(y: expandedOffsetY - p * collapseTravel)
        .animation(.easeInOut(duration: 0.18), value: p)
        .zIndex(1)
    }
}

