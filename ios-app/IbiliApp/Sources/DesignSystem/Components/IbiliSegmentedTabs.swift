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

enum FeedSegmentedHeaderMetrics {
    // Matches the current custom large-title layout: ~49pt top gap,
    // ~41pt title line height, ~12pt bottom pad.
    static let expandedHeight: CGFloat = 102
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
                .onPreferenceChange(ScrollHeaderOffsetPreferenceKey.self) { minY in
                    progress = min(max(-minY / 16, 0), 1)
                }
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

struct FeedNavigationBackgroundOverlay: View {
    /// 0 → fully expanded (large title), 1 → fully collapsed (inline).
    let collapseProgress: CGFloat

    var body: some View {
        let p = min(1, max(0, collapseProgress))

        LinearGradient(
            colors: [
                Color.black.opacity(0.30),
                Color.black.opacity(0.14),
                Color.black.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: FeedSegmentedHeaderMetrics.expandedHeight + 20, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .opacity(0.72 + p * 0.28)
        .allowsHitTesting(false)
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
        // Title size eases from 34pt (.largeTitle bold) to 17pt
        // (.headline semibold) to mirror the system large-title
        // collapse animation.
        let titleSize = 34 - p * 17
        let titleWeight: Font.Weight = p > 0.5 ? .semibold : .bold
        // The system large-title bar reserves ~44pt for the inline
        // toolbar row above the large title. We reproduce that gap so
        // our custom header lines up vertically with sibling tabs
        // (e.g. "我的") that still use the stock navigation bar.
        // As the user scrolls and the title shrinks, the gap shrinks
        // with it so the small inline title ends up vertically
        // centred in the 44pt inline-bar slot — matching iOS.
        let topPad: CGFloat = 52 - p * 35
        let bottomPad: CGFloat = 10 - p * 6

        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: titleSize, weight: titleWeight))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            NavigationTrailingSegmentedControl(
                tabs: tabs,
                title: tabTitle,
                selection: $selection
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .frame(height: FeedSegmentedHeaderMetrics.expandedHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            // Top navigation cover: a black transparent gradient that
            // sits behind the custom header, extending through the
            // status-bar area so content can continue underneath while
            // the chrome stays readable. This replaces the previous
            // bottom shadow strip.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.14),
                    Color.black.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: FeedSegmentedHeaderMetrics.expandedHeight + 20)
            .ignoresSafeArea(edges: .top)
            .opacity(0.72 + p * 0.28)
            .allowsHitTesting(false)
        }
    }
}

struct FeedFloatingSegmentedControlOverlay<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab
    /// 0 → fully expanded (large title), 1 → fully collapsed (inline).
    let collapseProgress: CGFloat

    var body: some View {
        let p = min(1, max(0, collapseProgress))
        let topPad: CGFloat = 52 - p * 35

        NavigationTrailingSegmentedControl(
            tabs: tabs,
            title: title,
            selection: $selection
        )
        .padding(.trailing, 16)
        .padding(.top, topPad)
        .frame(height: FeedSegmentedHeaderMetrics.expandedHeight, alignment: .topTrailing)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
    }
}

struct FeedTitleHeader: View {
    let title: String
    /// 0 → fully expanded (large title), 1 → fully collapsed (inline).
    let collapseProgress: CGFloat
    var showsBackground: Bool = true

    var body: some View {
        let p = min(1, max(0, collapseProgress))
        let titleSize = 34 - p * 17
        let titleWeight: Font.Weight = p > 0.5 ? .semibold : .bold
        let topPad: CGFloat = 52 - p * 35
        let bottomPad: CGFloat = 10 - p * 6

        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: titleSize, weight: titleWeight))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .frame(height: FeedSegmentedHeaderMetrics.expandedHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            if showsBackground {
                FeedNavigationBackgroundOverlay(collapseProgress: collapseProgress)
            }
        }
    }
}
