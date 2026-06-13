import SwiftUI

struct FeedChrome<Tab: Hashable & Identifiable, Content: View>: View {
    let title: String
    let tabs: [Tab]
    let tabTitle: (Tab) -> String
    @Binding var selection: Tab
    @Binding var headerCollapseProgress: CGFloat
    let content: Content

    init(
        title: String,
        tabs: [Tab],
        tabTitle: @escaping (Tab) -> String,
        selection: Binding<Tab>,
        headerCollapseProgress: Binding<CGFloat>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tabs = tabs
        self.tabTitle = tabTitle
        self._selection = selection
        self._headerCollapseProgress = headerCollapseProgress
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.feedChromeShowsInlineSystemHeader, true)
            .background(IbiliTheme.background.ignoresSafeArea())
            .overlay(alignment: .top) {
                FeedNavigationBackgroundOverlay(collapseProgress: headerCollapseProgress)
            }
            .modifier(FeedChromeNavigationModifier(
                tabs: tabs,
                tabTitle: tabTitle,
                selection: $selection
            ))
    }
}

private struct FeedChromeShowsInlineSystemHeaderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var feedChromeShowsInlineSystemHeader: Bool {
        get { self[FeedChromeShowsInlineSystemHeaderKey.self] }
        set { self[FeedChromeShowsInlineSystemHeaderKey.self] = newValue }
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

private struct FeedChromeNavigationModifier<Tab: Hashable & Identifiable>: ViewModifier {
    let tabs: [Tab]
    let tabTitle: (Tab) -> String
    @Binding var selection: Tab

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ForEach(tabs) { tab in
                        FeedToolbarTabButton(
                            title: tabTitle(tab),
                            isSelected: tab == selection
                        ) {
                            guard tab != selection else { return }
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                selection = tab
                            }
                        }
                    }
                }
            }
    }
}

private struct FeedToolbarTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? IbiliTheme.accent : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .tint(isSelected ? IbiliTheme.accent : .white)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct FeedScrollPage<Content: View>: View {
    let title: String
    let coordinateSpace: String
    let scrollToTopSignal: Int
    @Binding var headerCollapseProgress: CGFloat
    var showsRefresh: Bool = false
    var onRefresh: (() async -> Void)?
    let content: Content
    @Environment(\.feedChromeShowsInlineSystemHeader) private var showsInlineSystemHeader
    @State private var scrollOffset: CGFloat = 0

    init(
        title: String,
        coordinateSpace: String,
        scrollToTopSignal: Int = 0,
        headerCollapseProgress: Binding<CGFloat>,
        showsRefresh: Bool = false,
        onRefresh: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.coordinateSpace = coordinateSpace
        self.scrollToTopSignal = scrollToTopSignal
        self._headerCollapseProgress = headerCollapseProgress
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
                if !showsInlineSystemHeader {
                    FeedTitleHeader(title: title, collapseProgress: headerCollapseProgress, showsBackground: false)
                }
                content
            }
            .overlay(alignment: .topLeading) {
                if showsInlineSystemHeader {
                    FeedChromeFloatingTitle(
                        title: title,
                        scrollOffset: scrollOffset
                    )
                }
            }
            .onChange(of: scrollToTopSignal) { _ in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    scrollProxy.scrollTo(topAnchorID, anchor: .top)
                }
                headerCollapseProgress = 0
                scrollOffset = 0
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
        .modifier(ScrollOffsetCollapseDriver(
            progress: $headerCollapseProgress,
            offset: $scrollOffset
        ))
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

private struct FeedChromeFloatingTitle: View {
    let title: String
    let scrollOffset: CGFloat

    var body: some View {
        let progress = min(max(scrollOffset / 44, 0), 1)
        let baseYOffset: CGFloat = -32
        let yOffset = baseYOffset - scrollOffset
        let opacity = Double(1 - progress)

        Text(title)
            .font(.largeTitle.bold())
            .foregroundStyle(IbiliTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .padding(.leading, 16)
            .padding(.top, 0)
            .offset(y: yOffset)
            .opacity(opacity)
        .allowsHitTesting(false)
    }
}
