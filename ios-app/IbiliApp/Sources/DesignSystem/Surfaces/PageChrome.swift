import SwiftUI

struct FeedChrome<Tab: Hashable & Identifiable, Content: View>: View {
    let title: String
    let tabs: [Tab]
    let tabTitle: (Tab) -> String
    @Binding var selection: Tab
    @Binding var headerCollapseProgress: CGFloat
    @Binding var switcherCollapseProgress: CGFloat
    var hidesNavigationBar: Bool = true
    let content: Content

    init(
        title: String,
        tabs: [Tab],
        tabTitle: @escaping (Tab) -> String,
        selection: Binding<Tab>,
        headerCollapseProgress: Binding<CGFloat>,
        switcherCollapseProgress: Binding<CGFloat>,
        hidesNavigationBar: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tabs = tabs
        self.tabTitle = tabTitle
        self._selection = selection
        self._headerCollapseProgress = headerCollapseProgress
        self._switcherCollapseProgress = switcherCollapseProgress
        self.hidesNavigationBar = hidesNavigationBar
        self.content = content()
    }

    var body: some View {
        content
            .background(IbiliTheme.background.ignoresSafeArea())
            .overlay(alignment: .top) {
                FeedNavigationBackgroundOverlay(collapseProgress: headerCollapseProgress)
            }
            .overlay(alignment: .top) {
                FeedFloatingSegmentedControlOverlay(
                    tabs: tabs,
                    title: tabTitle,
                    selection: $selection,
                    collapseProgress: switcherCollapseProgress,
                    positionProgress: headerCollapseProgress
                )
            }
            .modifier(HiddenNavigationBarModifier(isHidden: hidesNavigationBar))
    }
}

struct TitlePageChrome<Content: View>: View {
    @Binding var headerCollapseProgress: CGFloat
    var hidesNavigationBar: Bool = true
    let content: Content

    init(
        headerCollapseProgress: Binding<CGFloat>,
        hidesNavigationBar: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self._headerCollapseProgress = headerCollapseProgress
        self.hidesNavigationBar = hidesNavigationBar
        self.content = content()
    }

    var body: some View {
        content
            .background(IbiliTheme.background.ignoresSafeArea())
            .overlay(alignment: .top) {
                FeedNavigationBackgroundOverlay(collapseProgress: headerCollapseProgress)
            }
            .modifier(HiddenNavigationBarModifier(isHidden: hidesNavigationBar))
    }
}

private struct HiddenNavigationBarModifier: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden {
            content.toolbar(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}

struct FeedScrollPage<Content: View>: View {
    let title: String
    let coordinateSpace: String
    let scrollToTopSignal: Int
    @Binding var headerCollapseProgress: CGFloat
    private let switcherCollapseProgress: Binding<CGFloat>?
    var showsRefresh: Bool = false
    var onRefresh: (() async -> Void)?
    let content: Content

    init(
        title: String,
        coordinateSpace: String,
        scrollToTopSignal: Int = 0,
        headerCollapseProgress: Binding<CGFloat>,
        switcherCollapseProgress: Binding<CGFloat>? = nil,
        showsRefresh: Bool = false,
        onRefresh: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.coordinateSpace = coordinateSpace
        self.scrollToTopSignal = scrollToTopSignal
        self._headerCollapseProgress = headerCollapseProgress
        self.switcherCollapseProgress = switcherCollapseProgress
        self.showsRefresh = showsRefresh
        self.onRefresh = onRefresh
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            refreshableScroll {
                Color.clear.frame(height: 0).id(topAnchorID)
                if #unavailable(iOS 18.0) {
                    ScrollHeaderOffsetReader(coordinateSpace: coordinateSpace)
                }
                FeedTitleHeader(title: title, collapseProgress: headerCollapseProgress, showsBackground: false)
                content
            }
            .onChange(of: scrollToTopSignal) { _ in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    scrollProxy.scrollTo(topAnchorID, anchor: .top)
                }
                headerCollapseProgress = 0
                switcherCollapseProgress?.wrappedValue = 0
            }
        }
    }

    private var topAnchorID: String {
        "\(coordinateSpace)-top"
    }

    @ViewBuilder
    private func refreshableScroll(@ViewBuilder content: () -> some View) -> some View {
        let scroll = ScrollView {
            content()
        }
        .coordinateSpace(name: coordinateSpace)
        .modifier(ScrollOffsetCollapseDriver(progress: $headerCollapseProgress, switcherProgress: switcherCollapseProgress ?? .constant(0)))
        .modifier(ProMotionScrollHint())
        .scrollContentBackground(.hidden)

        if showsRefresh, let onRefresh {
            scroll.refreshable {
                await onRefresh()
            }
        } else {
            scroll
        }
    }
}
