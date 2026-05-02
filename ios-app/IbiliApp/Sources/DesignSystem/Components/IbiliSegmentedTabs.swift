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

/// Reliable collapse-progress driver for `FeedSegmentedHeader`.
///
/// On iOS 18+ this hooks into `onScrollGeometryChange`, which is the
/// official Apple API for observing live scroll offset on a
/// `ScrollView` and fires every frame the user drags. Older
/// versions keep the existing `GeometryReader`/`PreferenceKey` path.
struct ScrollOffsetCollapseDriver: ViewModifier {
    @Binding var progress: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newValue in
                progress = min(max(newValue / 16, 0), 1)
            }
        } else {
            content
        }
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

/// Custom large-title header used by feed-style tabs (Home, Dynamic).
///
/// SwiftUI's stock navigation bar renders the trailing toolbar items
/// in the inline row at the very top, while the large title lives in
/// a separate row underneath. That layout makes it impossible to have
/// the segmented control sit *on the same row* as the large title,
/// and once the title collapses the inline label is forced to the
/// horizontal centre. Drawing the header ourselves with
/// `safeAreaInset(.top)` solves both: the title and the capsule live
/// in a single `HStack`, and the title text simply shrinks in place
/// (staying left-aligned) as the user scrolls.
struct FeedSegmentedHeader<Tab: Hashable & Identifiable>: View {
    let title: String
    let tabs: [Tab]
    let tabTitle: (Tab) -> String
    @Binding var selection: Tab
    /// 0 → fully expanded (large title), 1 → fully collapsed (inline).
    let collapseProgress: CGFloat

    var body: some View {
        let p = min(1, max(0, collapseProgress))

        // KEY DESIGN: every visual change here is expressed via
        // `scaleEffect` / `offset` rather than padding / font-size /
        // frame changes. The header therefore keeps a *constant
        // layout height* even though it visibly shrinks. That breaks
        // the feedback loop that previously caused the Dynamic feed
        // to jitter — when `safeAreaInset` height changes mid-scroll,
        // the ScrollView's `contentOffset` is reflowed, which in turn
        // changes `collapseProgress`, which changes the inset again.
        // With layout-stable transforms the loop cannot start.

        // Title: 34pt → 17pt is a 0.5x scale. Anchor at .leading so
        // it shrinks in place against the left edge.
        let titleScale = 1 - p * 0.5

        // Vertical travel: the expanded layout has the title sitting
        // 22pt below the inline-bar slot, so we lift the whole row
        // up by that much as it collapses, mirroring the system
        // large-title fold-up animation.
        let liftY: CGFloat = -p * 22

        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .scaleEffect(titleScale, anchor: .leading)
            Spacer(minLength: 0)
            NavigationTrailingSegmentedControl(
                tabs: tabs,
                title: tabTitle,
                selection: $selection
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: liftY)
        .background(
            // Solid page-background fill so feed content does not
            // bleed through the bar. We deliberately leave this
            // un-shadowed and un-blurred per the latest design call.
            IbiliTheme.background
                .ignoresSafeArea(edges: .top)
        )
    }
}
