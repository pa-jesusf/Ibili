import SwiftUI
import UIKit

extension EnvironmentValues {
    var isInPlayerHostNavigation: Bool {
        get { self[IsInPlayerHostNavigationKey.self] }
        set { self[IsInPlayerHostNavigationKey.self] = newValue }
    }

    var prefersSplitRootSelection: Bool {
        get { self[PrefersSplitRootSelectionKey.self] }
        set { self[PrefersSplitRootSelectionKey.self] = newValue }
    }

    var splitRootIsActive: Bool {
        get { self[SplitRootIsActiveKey.self] }
        set { self[SplitRootIsActiveKey.self] = newValue }
    }

    var splitFeedColumnLimit: Int? {
        get { self[SplitFeedColumnLimitKey.self] }
        set { self[SplitFeedColumnLimitKey.self] = newValue }
    }

    var splitPreviewLeftWidth: CGFloat? {
        get { self[SplitPreviewLeftWidthKey.self] }
        set { self[SplitPreviewLeftWidthKey.self] = newValue }
    }

    var dismissPlayerHost: () -> Void {
        get { self[DismissPlayerHostKey.self] }
        set { self[DismissPlayerHostKey.self] = newValue }
    }

    var beginNativePlayerFullscreenExit: () -> Void {
        get { self[BeginNativePlayerFullscreenExitKey.self] }
        set { self[BeginNativePlayerFullscreenExitKey.self] = newValue }
    }

    var endNativePlayerFullscreenExit: () -> Void {
        get { self[EndNativePlayerFullscreenExitKey.self] }
        set { self[EndNativePlayerFullscreenExitKey.self] = newValue }
    }

}

private struct IsInPlayerHostNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PrefersSplitRootSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SplitRootIsActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SplitFeedColumnLimitKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

private struct SplitPreviewLeftWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct DismissPlayerHostKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct BeginNativePlayerFullscreenExitKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct EndNativePlayerFullscreenExitKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private enum MainTab: Hashable, CustomStringConvertible {
    case home
    case dynamic
    case profile
    case search

    var description: String {
        switch self {
        case .home:
            return "home"
        case .dynamic:
            return "dynamic"
        case .profile:
            return "profile"
        case .search:
            return "search"
        }
    }
}

/// Top-level shell. Switches between login and main tab interface.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject var session: AppSession
    @StateObject private var router = DeepLinkRouter()
    @State private var selectedMainTab: MainTab = .home
    @State private var retainsDismissedPlayerHost = false
    @State private var releaseDismissedPlayerHostWork: DispatchWorkItem?
    @State private var splitDetailProgress: CGFloat = 0
    @State private var splitRootDismissWork: DispatchWorkItem?
    @State private var splitLayoutBaseSize: CGSize?
    @State private var lastStableMainTab: MainTab = .home
    @State private var rootContentPath: [RootContentRoute] = []
    @StateObject private var presentationGuard = PlayerPresentationNavigationGuard()

    var body: some View {
        GeometryReader { proxy in
            let canSplit = isIPadLandscapeSplitCandidate(size: proxy.size, stableBaseSize: splitLayoutBaseSize)
            let usesSplit = canSplit && router.pending != nil && session.isLoggedIn

            ZStack {
                if session.isLoggedIn {
                    mainContent(size: proxy.size, canSplit: canSplit, usesSplit: usesSplit)
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }

                // Player is presented as a horizontal-slide overlay above
                // the tab interface — *not* a `.fullScreenCover` — so that
                // the user's right-edge swipe-back actually reveals the
                // previous screen (home / search) underneath instead of a
                // black backdrop. The host drives its own slide-in/out
                // animation off a single offset state so SwiftUI's render
                // loop can keep it on the ProMotion 120 Hz path; we
                // deliberately don't combine `.transition(.move)` with a
                // separate offset, because that doubles up the work and
                // tends to fall back to 60 Hz.
                if !usesSplit, router.pending != nil || retainsDismissedPlayerHost {
                    DeepLinkPlayerHost(onRootDismissed: retainDismissedPlayerHost)
                        .environmentObject(router)
                        .environmentObject(presentationGuard)
                        .tint(IbiliTheme.accent)
                        .zIndex(1)
                }
            }
            .onChange(of: usesSplit) { splitActive in
                if splitActive {
                    releaseDismissedPlayerHostWork?.cancel()
                    releaseDismissedPlayerHostWork = nil
                    retainsDismissedPlayerHost = false
                    splitLayoutBaseSize = proxy.size
                }
                updateSplitDetailProgress(isActive: splitActive)
            }
            .onChange(of: proxy.size) { newSize in
                handleRootSizeChange(newSize)
            }
            .onAppear {
                handleRootSizeChange(proxy.size)
            }
        }
        .environmentObject(router)
        .environment(\.openURL, OpenURLAction { url in
            NavigationTrace.log("Root openURL", metadata: [
                "url": url.absoluteString,
            ], includeStack: true)
            return router.handle(url)
        })
        .background(NavigationTraceTouchObserver())
        .navigationTracePage("RootView", metadata: [
            "selectedTab": "\(selectedMainTab)",
            "isLoggedIn": String(session.isLoggedIn),
            "pending": router.pending?.navigationTraceSummary ?? "nil",
            "pathDepth": String(router.path.count),
            "path": NavigationTrace.sessionPathSummary(router.path),
        ])
        .onChange(of: router.pending?.id) { newValue in
            NavigationTrace.log("Root 观察 pending 变化", metadata: [
                "pendingID": newValue?.uuidString ?? "nil",
                "pending": router.pending?.navigationTraceSummary ?? "nil",
                "pathDepth": String(router.path.count),
                "path": NavigationTrace.sessionPathSummary(router.path),
            ], includeStack: true)
            guard newValue != nil else { return }
            splitRootDismissWork?.cancel()
            splitRootDismissWork = nil
            splitDetailProgress = 1
            releaseDismissedPlayerHostWork?.cancel()
            releaseDismissedPlayerHostWork = nil
            retainsDismissedPlayerHost = false
        }
        .onChange(of: selectedMainTab) { newValue in
            handleMainTabSelectionChanged(newValue)
        }
        .onChange(of: session.isLoggedIn) { _ in
            NavigationTrace.log("Root 登录态变化", metadata: [
                "isLoggedIn": String(session.isLoggedIn),
                "selectedTab": "\(selectedMainTab)",
            ], includeStack: true)
            splitDetailProgress = 0
            splitLayoutBaseSize = nil
        }
    }

    @ViewBuilder
    private func mainContent(size: CGSize, canSplit: Bool, usesSplit: Bool) -> some View {
        if canSplit {
            let splitMetrics = splitLayoutMetrics(size: size, usesSplit: usesSplit)
            ZStack(alignment: .leading) {
                RootContentNavigationStack(
                    name: "root-tabs",
                    path: $rootContentPath,
                    onMediaRoutesChanged: syncRootContentMediaSessions
                ) {
                    MainTabView(selectedTab: $selectedMainTab)
                }
                    .environmentObject(presentationGuard)
                    .environment(\.prefersSplitRootSelection, true)
                    .environment(\.splitRootIsActive, usesSplit)
                    .environment(\.splitFeedColumnLimit, splitMetrics.feedColumnLimit)
                    .environment(\.splitPreviewLeftWidth, splitMetrics.previewLeftWidth)
                    .frame(width: splitMetrics.leftWidth, height: size.height)
                    .clipped()
                    .transaction { $0.animation = nil }

                Divider()
                    .ignoresSafeArea(edges: .vertical)
                    .opacity(usesSplit ? 1 : 0)
                    .frame(width: 1, height: size.height)
                    .offset(x: splitMetrics.leftWidth)

                DeepLinkSplitHost(onRootDismiss: dismissSplitRoot)
                    .environmentObject(router)
                    .environmentObject(presentationGuard)
                    .tint(.white)
                    .frame(width: splitMetrics.rightWidth, height: size.height)
                    .clipped()
                    .offset(x: splitMetrics.leftWidth + 1 + splitMetrics.rightWidth * (1 - splitDetailProgress))
                    .opacity(splitDetailProgress > 0.01 ? 1 : 0)
                    .allowsHitTesting(usesSplit)
                    .compositingGroup()
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(IbiliTheme.background.ignoresSafeArea())
        } else {
            RootContentNavigationStack(
                name: "root-tabs",
                path: $rootContentPath,
                onMediaRoutesChanged: syncRootContentMediaSessions
            ) {
                MainTabView(selectedTab: $selectedMainTab)
            }
                .environmentObject(presentationGuard)
                .environment(\.prefersSplitRootSelection, false)
                .environment(\.splitRootIsActive, false)
                .environment(\.splitFeedColumnLimit, nil)
                .environment(\.splitPreviewLeftWidth, nil)
        }
    }

    private func updateSplitDetailProgress(isActive: Bool) {
        splitRootDismissWork?.cancel()
        splitRootDismissWork = nil
        if isActive {
            splitDetailProgress = 0
            DispatchQueue.main.async {
                withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.9, blendDuration: 0)) {
                    splitDetailProgress = 1
                }
            }
        } else {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.92, blendDuration: 0)) {
                splitDetailProgress = 0
            }
        }
    }

    private func dismissSplitRoot() {
        guard router.pending != nil else { return }
        splitRootDismissWork?.cancel()
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.92, blendDuration: 0)) {
            splitDetailProgress = 0
        }
        let dismissingRouteID = router.pending?.id
        let work = DispatchWorkItem {
            guard router.pending?.id == dismissingRouteID,
                  router.path.count <= 1 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                router.closeSession()
            }
            splitLayoutBaseSize = nil
            splitRootDismissWork = nil
        }
        splitRootDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    private struct SplitLayoutMetrics: Equatable {
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let feedColumnLimit: Int?
        let previewLeftWidth: CGFloat?
    }

    private func splitLayoutMetrics(size: CGSize, usesSplit: Bool) -> SplitLayoutMetrics {
        let fullColumns = min(max(settings.effectiveColumns(horizontal: .regular, width: size.width), 1), 4)
        let targetColumns = max(1, (fullColumns + 1) / 2)
        let horizontalPadding: CGFloat = 12
        let spacing: CGFloat = 12
        let fullCardWidth = max(
            1,
            floor((size.width - horizontalPadding * 2 - spacing * CGFloat(fullColumns - 1)) / CGFloat(fullColumns))
        )
        let idealLeftWidth = fullCardWidth * CGFloat(targetColumns)
            + spacing * CGFloat(max(0, targetColumns - 1))
            + horizontalPadding * 2
        let minRightWidth = min(max(size.width * 0.30, 360), 520)
        let maxLeftWidth = max(1, size.width - minRightWidth - 1)
        let targetLeftWidth = floor(min(max(idealLeftWidth, 360), maxLeftWidth))
        guard usesSplit else {
            return SplitLayoutMetrics(
                leftWidth: size.width,
                rightWidth: 0,
                feedColumnLimit: nil,
                previewLeftWidth: targetLeftWidth
            )
        }
        return SplitLayoutMetrics(
            leftWidth: targetLeftWidth,
            rightWidth: max(0, size.width - targetLeftWidth - 1),
            feedColumnLimit: targetColumns,
            previewLeftWidth: targetLeftWidth
        )
    }

    private func isIPadLandscapeSplitCandidate(size: CGSize, stableBaseSize: CGSize?) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        let stableSize = stableRootLayoutSize(fallback: size)
        guard stableSize.width >= 900 else { return false }
        if let stableBaseSize {
            return stableBaseSize.width > stableBaseSize.height
                && stableBaseSize.width >= 900
                && stableBaseSize.height >= 600
        }
        return interfaceIsLandscape(size: stableSize) && stableSize.height >= 600
    }

    private func handleRootSizeChange(_ size: CGSize) {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            splitLayoutBaseSize = nil
            return
        }
        if router.pending == nil || !session.isLoggedIn {
            splitLayoutBaseSize = nil
            return
        }
        guard let base = splitLayoutBaseSize else { return }
        let stableSize = stableRootLayoutSize(fallback: size)
        if stableSize.width < 900 || !interfaceIsLandscape(size: stableSize) {
            splitLayoutBaseSize = nil
        } else if stableSize.width > base.width + 1 || stableSize.height > base.height + 1 {
            splitLayoutBaseSize = stableSize
        }
    }

    private func stableRootLayoutSize(fallback size: CGSize) -> CGSize {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return size }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return size
        }
        let windowBounds = scene.windows.first(where: \.isKeyWindow)?.bounds ?? scene.screen.bounds
        guard windowBounds.width > 0, windowBounds.height > 0 else { return size }
        return windowBounds.size
    }

    private func interfaceIsLandscape(size: CGSize) -> Bool {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            let orientation = scene.interfaceOrientation
            if orientation == .unknown {
                return size.width > size.height
            }
            return orientation.isLandscape
        }
        return size.width > size.height
    }

    private func retainDismissedPlayerHost(for interval: TimeInterval) {
        releaseDismissedPlayerHostWork?.cancel()
        retainsDismissedPlayerHost = true
        let work = DispatchWorkItem {
            guard router.pending == nil else { return }
            retainsDismissedPlayerHost = false
            releaseDismissedPlayerHostWork = nil
        }
        releaseDismissedPlayerHostWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func handleMainTabSelectionChanged(_ newValue: MainTab) {
        NavigationTrace.log("主 tab selection 变化", metadata: [
            "selectedTab": "\(newValue)",
            "lastStableTab": "\(lastStableMainTab)",
            "isProtectingNativeFullscreenExit": String(presentationGuard.isProtectingNativeFullscreenExit),
            "rootContentDepth": String(rootContentPath.count),
            "rootContentPath": NavigationTrace.rootContentPathSummary(rootContentPath),
            "pending": router.pending?.navigationTraceSummary ?? "nil",
            "pathDepth": String(router.path.count),
            "path": NavigationTrace.sessionPathSummary(router.path),
        ], includeStack: true)

        if presentationGuard.isProtectingNativeFullscreenExit,
           newValue == .home,
           lastStableMainTab != .home {
            NavigationTrace.log("还原原生全屏退出期间的首页 tab 回写", metadata: [
                "restoredTab": "\(lastStableMainTab)",
                "pending": router.pending?.navigationTraceSummary ?? "nil",
                "pathDepth": String(router.path.count),
                "path": NavigationTrace.sessionPathSummary(router.path),
            ], includeStack: true)
            let restoreTab = lastStableMainTab
            DispatchQueue.main.async {
                selectedMainTab = restoreTab
            }
            return
        }

        lastStableMainTab = newValue
    }

    private var foregroundRootContentPlayerRouteID: UUID? {
        guard case .player(let route)? = rootContentPath.last else { return nil }
        return route.id
    }

    private var foregroundRootContentLiveRouteID: UUID? {
        guard case .live(let route)? = rootContentPath.last else { return nil }
        return route.id
    }

    private func syncRootContentMediaSessions() {
        PlayerRuntimeCoordinator.shared.retainSessions(
            root: nil,
            stack: router.playerPath + rootContentPath.compactMap(\.playerRoute),
            foregroundRouteID: foregroundRootContentPlayerRouteID ?? router.foregroundPlayerRouteID
        )
        LiveRuntimeCoordinator.shared.retainSessions(
            root: nil,
            stack: router.livePath + rootContentPath.compactMap(\.liveRoute),
            foregroundRouteID: foregroundRootContentLiveRouteID ?? router.foregroundLiveRouteID
        )
    }
}

@MainActor
final class PlayerPresentationNavigationGuard: ObservableObject {
    private var fullscreenExitProtectionDeadline = Date.distantPast
    private var releaseWork: DispatchWorkItem?

    var isProtectingNativeFullscreenExit: Bool {
        Date() < fullscreenExitProtectionDeadline
    }

    func beginNativeFullscreenExitProtection() {
        armNativeFullscreenExitProtection()
    }

    func endNativeFullscreenExitProtection() {
        armNativeFullscreenExitProtection()
    }

    func shouldAcceptPathChange(from oldPath: [DeepLinkRouter.SessionRoute],
                                to newPath: [DeepLinkRouter.SessionRoute]) -> Bool {
        guard isProtectingNativeFullscreenExit,
              newPath.count < oldPath.count,
              let oldForeground = oldPath.last,
              oldForeground.playerRoute != nil || oldForeground.liveRoute != nil else {
            return true
        }
        let newIDs = Set(newPath.map(\.id))
        let removedForeground = !newIDs.contains(oldForeground.id)
        if removedForeground {
            NavigationTrace.log("忽略原生全屏退出期间的导航栈收缩", metadata: [
                "oldDepth": String(oldPath.count),
                "newDepth": String(newPath.count),
                "foregroundRouteID": oldForeground.id.uuidString,
                "oldPath": NavigationTrace.sessionPathSummary(oldPath),
                "newPath": NavigationTrace.sessionPathSummary(newPath),
            ], includeStack: true)
        }
        return !removedForeground
    }

    private func armNativeFullscreenExitProtection() {
        fullscreenExitProtectionDeadline = Date().addingTimeInterval(PlayerTransientPauseSuppressionContext.nativeFullscreenExit.window)
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.releaseWork = nil
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerTransientPauseSuppressionContext.nativeFullscreenExit.window, execute: work)
    }
}

/// Wrapper that hosts the active media/content session above the tab UI.
/// The session itself is explicit (`router.pending`); SwiftUI's path binding
/// is allowed to mirror user pops inside the session, but not to create or
/// destroy the session by itself.
private struct DeepLinkPlayerHost: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var presentationGuard: PlayerPresentationNavigationGuard
    let onRootDismissed: (TimeInterval) -> Void
    /// Single source of truth for the host's horizontal position.
    /// Driven by:
    ///   - `onAppear`: animates from `screenWidth` → 0 (slide-in).
    ///   - swipe-back drag: tracks the user's finger directly.
    ///   - `dismiss()`: animates to `screenWidth` then clears
    ///     `router.pending`. Keeping a single state variable means
    ///     the only animation in flight is one CADisplayLink-driven
    ///     `.interactiveSpring`, which automatically opts into the
    ///     ProMotion 120 Hz path.
    @State private var offsetX: CGFloat = UIScreen.main.bounds.width
    @State private var pendingDismissWork: DispatchWorkItem?
    @State private var isRootDismissInFlight = false
    @State private var animatedInRouteID: UUID?
    @State private var displayedPath: [DeepLinkRouter.SessionRoute] = []
    /// Native UIKit-style spring. `interpolatingSpring` produces a
    /// physics curve that SwiftUI drives via the underlying
    /// `CADisplayLink`, which on ProMotion devices ticks at 120 Hz
    /// for the duration of the animation. Fixed-duration curves
    /// (`easeOut`, `linear`) clamp to the legacy 60 Hz path on some
    /// SwiftUI builds; springs do not.
    private static let slideSpring: Animation = .interactiveSpring(
        response: 0.34,
        dampingFraction: 0.86,
        blendDuration: 0
    )
    private static let hostReleaseGrace: TimeInterval = 0.85

    var body: some View {
        NavigationStack(path: controlledNavigationPath) {
            Color.clear
                .background(IbiliTheme.background)
            .navigationDestination(for: DeepLinkRouter.SessionRoute.self) { route in
                destinationView(for: route)
                    .id(route.id)
                    .environment(\.dismissPlayerHost, dismiss)
                    .navigationBarBackButtonHidden(router.path.count <= 1)
                    .toolbar { rootDismissToolbar(for: route) }
            }
        }
        .tint(.white)
        .environment(\.isInPlayerHostNavigation, true)
        .environment(\.rootContentNavigation, hostContentNavigation)
        .environment(\.beginNativePlayerFullscreenExit, presentationGuard.beginNativeFullscreenExitProtection)
        .environment(\.endNativePlayerFullscreenExit, presentationGuard.endNativeFullscreenExitProtection)
        .environment(\.openURL, OpenURLAction { url in
            handleLocalDeepLink(url)
        })
        .background(IbiliTheme.background)
        .offset(x: offsetX)
        .allowsHitTesting(!isRootDismissInFlight)
        .onAppear {
            NavigationTrace.pageAppear("DeepLinkPlayerHost", metadata: hostTraceMetadata(reason: "appear"))
            cancelPendingDismiss(resetRouterDismissal: true)
            if router.pending != nil {
                isRootDismissInFlight = false
            }
            syncPlayerSessions()
            animateHostInIfNeeded(for: router.pending?.id)
            syncDisplayedPathFromRouter(animated: true, deferToNextRunLoop: true)
            revealHostIfNeeded(reason: "appear")
        }
        .onChange(of: router.pending?.id) { newRouteID in
            NavigationTrace.log("播放器宿主观察 pending 变化", metadata: hostTraceMetadata(reason: "pending").merging([
                "newPendingID": newRouteID?.uuidString ?? "nil",
            ]) { current, _ in current }, includeStack: true)
            cancelPendingDismiss(resetRouterDismissal: true)
            if newRouteID != nil {
                isRootDismissInFlight = false
                router.cancelRootSessionDismissal()
                animateHostInIfNeeded(for: newRouteID)
                syncDisplayedPathFromRouter(animated: true, deferToNextRunLoop: true)
                revealHostIfNeeded(reason: "pending")
            } else {
                animatedInRouteID = nil
                displayedPath = []
            }
            syncPlayerSessions()
        }
        .onChange(of: router.path.map(\.id)) { _ in
            NavigationTrace.log("播放器宿主观察 router.path 变化", metadata: hostTraceMetadata(reason: "routerPath"), includeStack: true)
            cancelPendingDismiss(resetRouterDismissal: true)
            if router.pending != nil {
                isRootDismissInFlight = false
                router.cancelRootSessionDismissal()
                syncDisplayedPathFromRouter(animated: true)
                revealHostIfNeeded(reason: "path")
            }
            syncPlayerSessions()
        }
        // The root player is a custom slide-over host rather than a
        // UIKit navigation controller, so the system only gives us
        // edge-pop for pushed children. Install a pass-through pan
        // recognizer on the host view: horizontal right swipes from
        // anywhere in a player page dismiss/pop, while vertical
        // scrolling and normal taps continue to hit the content below.
        .overlay {
            PlayerHostAnyAreaSwipeBackInstaller(
                isEnabled: isAnyAreaPlayerSwipeBackEnabled,
                onChanged: handleAnyAreaSwipeBackChanged,
                onEnded: handleAnyAreaSwipeBackEnded,
                onCancelled: handleAnyAreaSwipeBackCancelled
            )
            .allowsHitTesting(false)
        }
        .onDisappear {
            NavigationTrace.pageDisappear("DeepLinkPlayerHost", metadata: hostTraceMetadata(reason: "disappear"))
            cancelPendingDismiss(resetRouterDismissal: true)
            isRootDismissInFlight = false
        }
    }

    /// Pop one navigation layer. If the player session has pushed
    /// child routes (related video / season episode), pop the top
    /// of `router.path` and let `NavigationStack` animate the pop
    /// natively — the slide host stays put. Only when we're already
    /// at the root pending route do we slide the host off-screen
    /// and then clear the session.
    ///
    /// Order matters: we kick off the slide spring FIRST so the
    /// animation has a frame budget, and only AFTER the spring's
    /// settle time do we tear the AVPlayer / HLS proxy / danmaku
    /// canvas down. Tearing them on the same runloop tick would
    /// stall the spring's first frame and re-introduce the visible
    /// "frozen" lag the user complained about.
    private func dismiss() {
        NavigationTrace.log("播放器宿主 dismiss 请求", metadata: hostTraceMetadata(reason: "dismiss"), includeStack: true)
        if router.path.count > 1 {
            router.popLastRoute()
            return
        }
        let width = UIScreen.main.bounds.width
        isRootDismissInFlight = true
        router.beginRootSessionDismissal()
        withAnimation(Self.slideSpring) {
            offsetX = width
        }
        cancelPendingDismiss(resetRouterDismissal: false)
        let dismissingRouteID = router.pending?.id
        let work = DispatchWorkItem {
            guard router.pending?.id == dismissingRouteID,
                  router.path.count <= 1 else { return }
            NavigationTrace.log("播放器宿主 root dismiss 执行关闭", metadata: hostTraceMetadata(reason: "dismissWork"), includeStack: true)
            onRootDismissed(Self.hostReleaseGrace)
            router.closeSession()
        }
        pendingDismissWork = work
        // Defer the heavy session teardown to a later runloop tick so
        // SwiftUI commits the slide animation before AVPlayer /
        // local-HLS / danmaku-displaylink deinit work seizes the main
        // thread. By the time the teardown runs, the host is already
        // off-screen, so the user never sees the freeze.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }

    @ToolbarContentBuilder
    private func rootDismissToolbar(for route: DeepLinkRouter.SessionRoute) -> some ToolbarContent {
        if router.path.count <= 1 {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    NavigationTrace.withUserAction("playerHost.backButton", metadata: route.navigationTraceMetadata) {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                        .fontWeight(.semibold)
                }
                .tint(.white)
            }
        }
    }

    private func cancelPendingDismiss(resetRouterDismissal: Bool) {
        pendingDismissWork?.cancel()
        pendingDismissWork = nil
        if resetRouterDismissal, isRootDismissInFlight {
            router.cancelRootSessionDismissal()
        }
    }

    private func animateHostInIfNeeded(for routeID: UUID?) {
        guard let routeID else { return }
        guard animatedInRouteID != routeID else { return }
        NavigationTrace.log("播放器宿主执行自定义滑入转场", metadata: [
            "routeID": routeID.uuidString,
            "transitionWorld": "root-content-to-session-host",
            "transitionMode": "custom-host-slide-in",
            "transitionBoundary": "world-boundary",
            "expectedToolbarMorph": "false",
        ].merging(hostTraceMetadata(reason: "animateHostIn")) { current, _ in current }, includeStack: true)
        offsetX = UIScreen.main.bounds.width
        withAnimation(Self.slideSpring) {
            offsetX = 0
        }
        animatedInRouteID = routeID
    }

    private func revealHostIfNeeded(reason: String) {
        guard router.pending != nil, offsetX > 0.5 else { return }
        AppLog.debug("router", "恢复播放器宿主可见", metadata: [
            "reason": reason,
            "offsetX": String(format: "%.1f", offsetX),
            "pendingID": router.pending?.id.uuidString ?? "nil",
            "pathDepth": String(router.path.count),
        ])
        withAnimation(Self.slideSpring) {
            offsetX = 0
        }
    }

    private func syncPlayerSessions() {
        PlayerRuntimeCoordinator.shared.retainSessions(
            root: nil,
            stack: router.playerPath,
            foregroundRouteID: router.foregroundPlayerRouteID
        )
        LiveRuntimeCoordinator.shared.retainSessions(
            root: nil,
            stack: router.livePath,
            foregroundRouteID: router.foregroundLiveRouteID
        )
    }

    private func handleLocalDeepLink(_ url: URL) -> OpenURLAction.Result {
        router.handle(url)
    }

    @ViewBuilder
    private func destinationView(for route: DeepLinkRouter.SessionRoute) -> some View {
        DeepLinkRouteContent.destinationView(
            for: route,
            onPictureInPictureActiveChange: handlePictureInPictureChange,
            onPictureInPictureRestore: restorePictureInPicture
        )
    }

    private var isAnyAreaPlayerSwipeBackEnabled: Bool {
        guard router.pending != nil, !isRootDismissInFlight else { return false }
        return router.path.count <= 1
            && (router.path.last?.playerRoute != nil || router.path.last?.liveRoute != nil)
    }

    private func handleAnyAreaSwipeBackChanged(_ translationX: CGFloat) {
        guard isAnyAreaPlayerSwipeBackEnabled else { return }
        offsetX = min(max(translationX, 0), UIScreen.main.bounds.width)
    }

    private func handleAnyAreaSwipeBackEnded(translationX: CGFloat, velocityX: CGFloat) {
        guard isAnyAreaPlayerSwipeBackEnabled else {
            handleAnyAreaSwipeBackCancelled()
            return
        }
        if translationX > 80 || velocityX > 650 {
            NavigationTrace.log("播放器宿主任意区域滑动返回触发", metadata: [
                "translationX": String(format: "%.1f", translationX),
                "velocityX": String(format: "%.1f", velocityX),
            ].merging(hostTraceMetadata(reason: "swipeBack")) { current, _ in current }, includeStack: true)
            dismiss()
        } else {
            handleAnyAreaSwipeBackCancelled()
        }
    }

    private func handleAnyAreaSwipeBackCancelled() {
        guard router.path.count <= 1 else { return }
        withAnimation(Self.slideSpring) {
            offsetX = 0
        }
    }

    private func handlePictureInPictureChange(_ isActive: Bool, routeID: UUID) {
        PlayerRuntimeCoordinator.shared.handle(.pictureInPictureChanged(isActive), for: routeID)
        PlayerRuntimeCoordinator.shared.setPictureInPictureActive(
            isActive,
            for: routeID,
            snapshot: isActive ? router.snapshot : nil
        )
        syncPlayerSessions()
    }

    private func restorePictureInPicture(routeID: UUID,
                                         completion: @escaping (Bool) -> Void) {
        if let snapshot = PlayerRuntimeCoordinator.shared.pictureInPictureSnapshot(for: routeID) {
            router.restore(snapshot)
            syncPlayerSessions()
            completion(true)
            return
        }
        completion(router.containsRoute(id: routeID))
    }

    private var controlledNavigationPath: Binding<[DeepLinkRouter.SessionRoute]> {
        Binding(
            get: { displayedPath },
            set: applyNavigationStackWrite
        )
    }

    private var hostContentNavigation: RootContentNavigationActions {
        RootContentNavigationActions(open: { route in
            NavigationTrace.log("播放器宿主内容导航请求", metadata: [
                "route": route.navigationTraceSummary,
                "transitionWorld": "session-host-stack",
                "transitionMode": "intent-native-navigation-stack-push",
                "transitionBoundary": "same-world",
                "expectedToolbarMorph": "true",
            ].merging(route.navigationTraceMetadata) { current, _ in current }, includeStack: true)
            switch route {
            case .player(let playerRoute):
                router.open(playerRoute.item)
            case .live(let liveRoute):
                router.openLive(
                    roomID: liveRoute.roomID,
                    title: liveRoute.title,
                    cover: liveRoute.cover,
                    anchorName: liveRoute.anchorName
                )
            case .userSpace(let mid):
                router.openUserSpace(mid: mid)
            case .dynamicDetail(let item):
                router.openDynamicDetail(item)
            case .article(let id, let kind):
                router.openArticle(id: id, kind: kind)
            case .search(let keyword):
                router.openSearch(keyword: keyword)
            }
        })
    }

    private func applyNavigationStackWrite(_ newPath: [DeepLinkRouter.SessionRoute]) {
        let accepted = DeepLinkNavigationPathCoordinator.shouldApply(
            displayedPath: displayedPath,
            routerPath: router.path,
            newPath: newPath,
            navigationGuard: presentationGuard
        )
        NavigationTrace.log(accepted ? "播放器宿主 NavigationStack path 写回" : "播放器宿主 NavigationStack path 写回被拒绝", metadata: [
            "displayedDepth": String(displayedPath.count),
            "routerDepth": String(router.path.count),
            "newDepth": String(newPath.count),
            "displayedPath": NavigationTrace.sessionPathSummary(displayedPath),
            "routerPath": NavigationTrace.sessionPathSummary(router.path),
            "newPath": NavigationTrace.sessionPathSummary(newPath),
        ], includeStack: true)
        guard accepted else { return }
        displayedPath = newPath
        router.replacePathFromNavigation(newPath)
    }

    private func syncDisplayedPathFromRouter(animated: Bool, deferToNextRunLoop: Bool = false) {
        let targetPath = router.path
        guard displayedPath.map(\.id) != targetPath.map(\.id) else { return }
        NavigationTrace.log("播放器宿主同步 router.path 到 displayedPath", metadata: [
            "animated": String(animated),
            "deferToNextRunLoop": String(deferToNextRunLoop),
            "oldDisplayedDepth": String(displayedPath.count),
            "targetDepth": String(targetPath.count),
            "oldDisplayedPath": NavigationTrace.sessionPathSummary(displayedPath),
            "targetPath": NavigationTrace.sessionPathSummary(targetPath),
            "transitionWorld": "session-host-stack",
            "transitionMode": transitionMode(fromDepth: displayedPath.count, toDepth: targetPath.count),
            "transitionBoundary": "same-world",
            "expectedToolbarMorph": String(targetPath.count > displayedPath.count),
        ], includeStack: true)
        let apply = {
            if animated {
                withAnimation {
                    displayedPath = targetPath
                }
            } else {
                displayedPath = targetPath
            }
        }
        if deferToNextRunLoop {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }

    private func hostTraceMetadata(reason: String) -> [String: String] {
        [
            "reason": reason,
            "pending": router.pending?.navigationTraceSummary ?? "nil",
            "routerDepth": String(router.path.count),
            "displayedDepth": String(displayedPath.count),
            "routerPath": NavigationTrace.sessionPathSummary(router.path),
            "displayedPath": NavigationTrace.sessionPathSummary(displayedPath),
            "offsetX": String(format: "%.1f", offsetX),
            "isRootDismissInFlight": String(isRootDismissInFlight),
        ]
    }

    private func transitionMode(fromDepth oldDepth: Int, toDepth newDepth: Int) -> String {
        if newDepth > oldDepth {
            return "native-navigation-stack-push-sync"
        }
        if newDepth < oldDepth {
            return "native-navigation-stack-pop-sync"
        }
        return "navigation-stack-replace-sync"
    }
}

struct DeepLinkRouteContent {
    @ViewBuilder
    @MainActor
    static func destinationView(
        for route: DeepLinkRouter.SessionRoute,
        onPictureInPictureActiveChange: @escaping (Bool, UUID) -> Void,
        onPictureInPictureRestore: @escaping (UUID, @escaping (Bool) -> Void) -> Void
    ) -> some View {
        switch route {
        case .player(let playerRoute):
            playerDestination(
                for: playerRoute,
                onPictureInPictureActiveChange: onPictureInPictureActiveChange,
                onPictureInPictureRestore: onPictureInPictureRestore
            )
            .id(playerRoute.id)
            .navigationTracePage("HostRoute:player", metadata: playerRoute.navigationTraceMetadata)
        case .live(let liveRoute):
            liveDestination(for: liveRoute)
                .id(liveRoute.id)
                .navigationTracePage("HostRoute:live", metadata: liveRoute.navigationTraceMetadata)
        case .userSpace(let userSpaceRoute):
            UserSpaceView(mid: userSpaceRoute.mid)
                .navigationTracePage("HostRoute:user", metadata: [
                    "routeID": userSpaceRoute.id.uuidString,
                    "mid": String(userSpaceRoute.mid),
                ])
        case .dynamicDetail(let detailRoute):
            DynamicDetailView(item: detailRoute.item)
                .navigationTracePage("HostRoute:dynamic", metadata: [
                    "routeID": detailRoute.id.uuidString,
                    "dynamicID": detailRoute.item.id,
                    "dynamicKind": "\(detailRoute.item.kind)",
                ])
        case .article(let articleRoute):
            ArticleView(articleID: articleRoute.articleID, kind: articleRoute.kind)
                .navigationTracePage("HostRoute:article", metadata: [
                    "routeID": articleRoute.id.uuidString,
                    "articleID": articleRoute.articleID,
                    "kind": articleRoute.kind,
                ])
        case .search(let searchRoute):
            SearchRouteView(keyword: searchRoute.keyword)
                .navigationTracePage("HostRoute:search", metadata: [
                    "routeID": searchRoute.id.uuidString,
                    "keyword": searchRoute.keyword,
                ])
        }
    }

    @MainActor
    static func playerDestination(
        for route: DeepLinkRouter.PlayerRoute,
        onPictureInPictureActiveChange: @escaping (Bool, UUID) -> Void,
        onPictureInPictureRestore: @escaping (UUID, @escaping (Bool) -> Void) -> Void
    ) -> some View {
        PlayerView(
            item: route.item,
            offlineOnly: route.offlineOnly,
            viewModel: PlayerRuntimeCoordinator.shared.viewModel(for: route.id),
            onPictureInPictureActiveChange: { isActive in
                onPictureInPictureActiveChange(isActive, route.id)
            },
            onPictureInPictureRestore: { completion in
                onPictureInPictureRestore(route.id, completion)
            }
        )
        .tint(.white)
    }

    @MainActor
    static func liveDestination(for route: DeepLinkRouter.LiveRoute) -> some View {
        LiveRoomView(
            route: route,
            vm: LiveRuntimeCoordinator.shared.viewModel(for: route.id)
        )
        .tint(.white)
    }

}

private struct DeepLinkSplitHost: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var presentationGuard: PlayerPresentationNavigationGuard
    let onRootDismiss: () -> Void
    @State private var displayedPath: [DeepLinkRouter.SessionRoute] = []

    var body: some View {
        NavigationStack(path: controlledNavigationPath) {
            splitEmptyState
            .navigationDestination(for: DeepLinkRouter.SessionRoute.self) { route in
                DeepLinkRouteContent.destinationView(
                    for: route,
                    onPictureInPictureActiveChange: handlePictureInPictureChange,
                    onPictureInPictureRestore: restorePictureInPicture
                )
                .id(route.id)
                .environment(\.dismissPlayerHost, dismiss)
                .navigationBarBackButtonHidden(router.path.count <= 1)
                .toolbar { rootDismissToolbar(for: route) }
            }
        }
        .tint(.white)
        .environment(\.isInPlayerHostNavigation, true)
        .environment(\.prefersSplitRootSelection, false)
        .environment(\.splitRootIsActive, true)
        .environment(\.rootContentNavigation, hostContentNavigation)
        .environment(\.beginNativePlayerFullscreenExit, presentationGuard.beginNativeFullscreenExitProtection)
        .environment(\.endNativePlayerFullscreenExit, presentationGuard.endNativeFullscreenExitProtection)
        .background(IbiliTheme.background)
        .onAppear {
            NavigationTrace.pageAppear("DeepLinkSplitHost", metadata: splitTraceMetadata(reason: "appear"))
            syncDisplayedPathFromRouter(animated: true, deferToNextRunLoop: true)
            syncPlayerSessions()
        }
        .onChange(of: router.pending?.id) { newRouteID in
            NavigationTrace.log("Split 宿主观察 pending 变化", metadata: splitTraceMetadata(reason: "pending").merging([
                "newPendingID": newRouteID?.uuidString ?? "nil",
            ]) { current, _ in current }, includeStack: true)
            router.cancelRootSessionDismissal()
            syncDisplayedPathFromRouter(animated: true, deferToNextRunLoop: true)
            syncPlayerSessions()
        }
        .onChange(of: router.path.map(\.id)) { _ in
            NavigationTrace.log("Split 宿主观察 router.path 变化", metadata: splitTraceMetadata(reason: "routerPath"), includeStack: true)
            router.cancelRootSessionDismissal()
            syncDisplayedPathFromRouter(animated: true)
            syncPlayerSessions()
        }
        .onDisappear {
            NavigationTrace.pageDisappear("DeepLinkSplitHost", metadata: splitTraceMetadata(reason: "disappear"))
            syncPlayerSessions()
        }
    }

    private var splitEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(IbiliTheme.textSecondary)
            Text("选择一个内容开始播放")
                .font(.subheadline)
                .foregroundStyle(IbiliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IbiliTheme.background)
    }

    private func dismiss() {
        NavigationTrace.log("Split 宿主 dismiss 请求", metadata: splitTraceMetadata(reason: "dismiss"), includeStack: true)
        if router.path.count > 1 {
            router.popLastRoute()
            return
        }
        onRootDismiss()
    }

    @ToolbarContentBuilder
    private func rootDismissToolbar(for route: DeepLinkRouter.SessionRoute) -> some ToolbarContent {
        if router.path.count <= 1 {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    NavigationTrace.withUserAction("splitHost.backButton", metadata: route.navigationTraceMetadata) {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .fontWeight(.semibold)
                }
                .tint(.white)
            }
        }
    }

    private func syncPlayerSessions() {
        PlayerRuntimeCoordinator.shared.retainSessions(
            root: nil,
            stack: router.playerPath,
            foregroundRouteID: router.foregroundPlayerRouteID
        )
        LiveRuntimeCoordinator.shared.retainSessions(
            root: nil,
            stack: router.livePath,
            foregroundRouteID: router.foregroundLiveRouteID
        )
    }

    private func handlePictureInPictureChange(_ isActive: Bool, routeID: UUID) {
        PlayerRuntimeCoordinator.shared.handle(.pictureInPictureChanged(isActive), for: routeID)
        PlayerRuntimeCoordinator.shared.setPictureInPictureActive(
            isActive,
            for: routeID,
            snapshot: isActive ? router.snapshot : nil
        )
        syncPlayerSessions()
    }

    private func restorePictureInPicture(routeID: UUID,
                                         completion: @escaping (Bool) -> Void) {
        if let snapshot = PlayerRuntimeCoordinator.shared.pictureInPictureSnapshot(for: routeID) {
            router.restore(snapshot)
            syncPlayerSessions()
            completion(true)
            return
        }
        completion(router.containsRoute(id: routeID))
    }

    private var controlledNavigationPath: Binding<[DeepLinkRouter.SessionRoute]> {
        Binding(
            get: { displayedPath },
            set: applyNavigationStackWrite
        )
    }

    private var hostContentNavigation: RootContentNavigationActions {
        RootContentNavigationActions(open: { route in
            NavigationTrace.log("Split 宿主内容导航请求", metadata: [
                "route": route.navigationTraceSummary,
                "transitionWorld": "split-session-host-stack",
                "transitionMode": "intent-native-navigation-stack-push",
                "transitionBoundary": "same-world",
                "expectedToolbarMorph": "true",
            ].merging(route.navigationTraceMetadata) { current, _ in current }, includeStack: true)
            switch route {
            case .player(let playerRoute):
                router.open(playerRoute.item)
            case .live(let liveRoute):
                router.openLive(
                    roomID: liveRoute.roomID,
                    title: liveRoute.title,
                    cover: liveRoute.cover,
                    anchorName: liveRoute.anchorName
                )
            case .userSpace(let mid):
                router.openUserSpace(mid: mid)
            case .dynamicDetail(let item):
                router.openDynamicDetail(item)
            case .article(let id, let kind):
                router.openArticle(id: id, kind: kind)
            case .search(let keyword):
                router.openSearch(keyword: keyword)
            }
        })
    }

    private func applyNavigationStackWrite(_ newPath: [DeepLinkRouter.SessionRoute]) {
        let accepted = DeepLinkNavigationPathCoordinator.shouldApply(
            displayedPath: displayedPath,
            routerPath: router.path,
            newPath: newPath,
            navigationGuard: presentationGuard
        )
        NavigationTrace.log(accepted ? "Split NavigationStack path 写回" : "Split NavigationStack path 写回被拒绝", metadata: [
            "displayedDepth": String(displayedPath.count),
            "routerDepth": String(router.path.count),
            "newDepth": String(newPath.count),
            "displayedPath": NavigationTrace.sessionPathSummary(displayedPath),
            "routerPath": NavigationTrace.sessionPathSummary(router.path),
            "newPath": NavigationTrace.sessionPathSummary(newPath),
        ], includeStack: true)
        guard accepted else { return }
        displayedPath = newPath
        router.replacePathFromNavigation(newPath)
    }

    private func syncDisplayedPathFromRouter(animated: Bool, deferToNextRunLoop: Bool = false) {
        let targetPath = router.path
        guard displayedPath.map(\.id) != targetPath.map(\.id) else { return }
        NavigationTrace.log("Split 同步 router.path 到 displayedPath", metadata: [
            "animated": String(animated),
            "deferToNextRunLoop": String(deferToNextRunLoop),
            "oldDisplayedDepth": String(displayedPath.count),
            "targetDepth": String(targetPath.count),
            "oldDisplayedPath": NavigationTrace.sessionPathSummary(displayedPath),
            "targetPath": NavigationTrace.sessionPathSummary(targetPath),
            "transitionWorld": "split-session-host-stack",
            "transitionMode": transitionMode(fromDepth: displayedPath.count, toDepth: targetPath.count),
            "transitionBoundary": "same-world",
            "expectedToolbarMorph": String(targetPath.count > displayedPath.count),
        ], includeStack: true)
        let apply = {
            if animated {
                withAnimation {
                    displayedPath = targetPath
                }
            } else {
                displayedPath = targetPath
            }
        }
        if deferToNextRunLoop {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }

    private func splitTraceMetadata(reason: String) -> [String: String] {
        [
            "reason": reason,
            "pending": router.pending?.navigationTraceSummary ?? "nil",
            "routerDepth": String(router.path.count),
            "displayedDepth": String(displayedPath.count),
            "routerPath": NavigationTrace.sessionPathSummary(router.path),
            "displayedPath": NavigationTrace.sessionPathSummary(displayedPath),
        ]
    }

    private func transitionMode(fromDepth oldDepth: Int, toDepth newDepth: Int) -> String {
        if newDepth > oldDepth {
            return "native-navigation-stack-push-sync"
        }
        if newDepth < oldDepth {
            return "native-navigation-stack-pop-sync"
        }
        return "navigation-stack-replace-sync"
    }
}

private struct PlayerHostAnyAreaSwipeBackInstaller: UIViewRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translationX: CGFloat, _ velocityX: CGFloat) -> Void
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.install(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateEnabled(isEnabled)
        context.coordinator.install(from: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerHostAnyAreaSwipeBackInstaller
        private weak var installedTarget: UIView?
        private weak var pan: UIPanGestureRecognizer?
        private var hasBegunSwipe = false

        init(parent: PlayerHostAnyAreaSwipeBackInstaller) {
            self.parent = parent
        }

        func install(from markerView: UIView) {
            DispatchQueue.main.async { [weak self, weak markerView] in
                guard let self, let markerView else { return }
                guard let target = markerView.window ?? markerView.superview?.window else { return }
                guard self.installedTarget !== target else { return }

                if let pan = self.pan, let oldTarget = self.installedTarget {
                    oldTarget.removeGestureRecognizer(pan)
                }

                let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
                pan.cancelsTouchesInView = false
                pan.delaysTouchesBegan = false
                pan.delaysTouchesEnded = false
                pan.delegate = self
                pan.isEnabled = self.parent.isEnabled
                target.addGestureRecognizer(pan)

                self.installedTarget = target
                self.pan = pan
            }
        }

        deinit {
            if let pan, let installedTarget {
                installedTarget.removeGestureRecognizer(pan)
            }
        }

        func updateEnabled(_ isEnabled: Bool) {
            pan?.isEnabled = isEnabled
            if !isEnabled || ModalGestureShield.isActive {
                hasBegunSwipe = false
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                if PlayerSwipeBackGestureExclusions.contains(
                    point: recognizer.location(in: recognizer.view),
                    in: recognizer.view
                ) {
                    hasBegunSwipe = false
                    parent.onCancelled()
                    return
                }
                hasBegunSwipe = true
            case .changed:
                guard hasBegunSwipe else { return }
                parent.onChanged(recognizer.translation(in: recognizer.view).x)
            case .ended:
                guard hasBegunSwipe else { return }
                hasBegunSwipe = false
                let translation = recognizer.translation(in: recognizer.view)
                let velocity = recognizer.velocity(in: recognizer.view)
                parent.onEnded(translation.x, velocity.x)
            case .cancelled, .failed:
                hasBegunSwipe = false
                parent.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.isEnabled,
                  !ModalGestureShield.isActive,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            guard !hasActivePresentedController(from: pan.view) else { return false }
            guard !PlayerSwipeBackGestureExclusions.contains(
                point: pan.location(in: pan.view),
                in: pan.view
            ) else { return false }
            guard !beganInsideHorizontalScrollView(pan) else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard velocity.x > 180 else { return false }
            return abs(velocity.x) > abs(velocity.y) * 1.35
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard parent.isEnabled,
                  !ModalGestureShield.isActive else { return false }
            if PlayerSwipeBackGestureExclusions.contains(touch, in: gestureRecognizer.view) {
                return false
            }
            if touch.view?.isInsideHorizontalScrollView == true {
                return false
            }
            var view = touch.view
            while let current = view {
                if current is UIControl {
                    return false
                }
                view = current.superview
            }
            return true
        }

        private func beganInsideHorizontalScrollView(_ pan: UIPanGestureRecognizer) -> Bool {
            guard let host = pan.view else { return false }
            let location = pan.location(in: host)
            guard let hitView = host.hitTest(location, with: nil) else { return false }
            return hitView.isInsideHorizontalScrollView
        }

        private func hasActivePresentedController(from view: UIView?) -> Bool {
            guard let root = view?.window?.rootViewController else { return false }
            return root.presentedViewController != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if PlayerSwipeBackGestureExclusions.isRegisteredOrDescendant(otherGestureRecognizer.view) {
                return false
            }
            return true
        }
    }
}

private extension UIView {
    var isInsideHorizontalScrollView: Bool {
        var view: UIView? = self
        while let current = view {
            if let scrollView = current as? UIScrollView,
               scrollView.bounds.width > 0,
               scrollView.contentSize.width > scrollView.bounds.width + 1,
               scrollView.alwaysBounceVertical == false {
                return true
            }
            view = current.superview
        }
        return false
    }
}

private struct MainTabView: View {
    @Binding var selectedTab: MainTab
    @StateObject private var tabReselect = TabReselectSignals()
    @State private var homeSection: HomeFeedSection = .recommend
    @State private var dynamicScope: DynamicFeedScope = .all

    var body: some View {
        // On iOS 18+ we use the new `Tab(role: .search)` initializer
        // so SwiftUI renders the search tab the way Apple Music does:
        // a separate magnifying-glass capsule next to the rest of the
        // tab bar that, when tapped, expands a long search field at
        // the bottom and collapses the other tabs into a single pill.
        // On iOS 16/17 we fall back to a plain extra `.tabItem`,
        // which still works but doesn't get the floating split look.
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("首页", systemImage: "house.fill", value: MainTab.home) {
                    HomeView(section: $homeSection)
                }
                Tab("动态", systemImage: "sparkles", value: MainTab.dynamic) {
                    DynamicFeedView(scope: $dynamicScope)
                }
                Tab("我的", systemImage: "person.crop.circle", value: MainTab.profile) {
                    ProfileView()
                }
                Tab(value: MainTab.search, role: .search) {
                    SearchView()
                }
            }
            .tint(IbiliTheme.accent)
            .tabViewStyle(.tabBarOnly)
            .toolbarBackground(.hidden, for: .tabBar)
            .environmentObject(tabReselect)
            .environment(\.feedChromeUsesExternalToolbar, true)
            .background(tabReselectObserver(order: [.home, .dynamic, .profile, .search]))
            .modifier(RootTabToolbarModifier(
                selectedTab: selectedTab,
                homeSection: $homeSection,
                dynamicScope: $dynamicScope
            ))
        } else {
            TabView(selection: $selectedTab) {
                HomeView(section: $homeSection)
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(MainTab.home)

                DynamicFeedView(scope: $dynamicScope)
                .tabItem { Label("动态", systemImage: "sparkles") }
                .tag(MainTab.dynamic)

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(MainTab.search)

                ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(MainTab.profile)
            }
            .tint(IbiliTheme.accent)
            .toolbarBackground(.hidden, for: .tabBar)
            .environmentObject(tabReselect)
            .environment(\.feedChromeUsesExternalToolbar, true)
            .background(tabReselectObserver(order: [.home, .dynamic, .search, .profile]))
            .modifier(RootTabToolbarModifier(
                selectedTab: selectedTab,
                homeSection: $homeSection,
                dynamicScope: $dynamicScope
            ))
        }
    }

    private func tabReselectObserver(order: [MainTab]) -> some View {
        TabBarReselectObserver(
            selectedTab: selectedTab,
            orderedTabs: order,
            onReselect: { tab in
                NavigationTrace.withUserAction("tab.reselect", metadata: [
                    "tab": "\(tab)",
                ]) {
                    NavigationTrace.log("根 tab 重复点击", metadata: [
                        "tab": "\(tab)",
                    ], includeStack: true)
                    switch tab {
                    case .home:
                        tabReselect.triggerHome()
                    case .dynamic:
                        tabReselect.triggerDynamic()
                    case .search:
                        tabReselect.triggerSearch()
                    case .profile:
                        tabReselect.triggerProfile()
                    }
                }
            }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

private struct RootTabToolbarModifier: ViewModifier {
    let selectedTab: MainTab
    @Binding var homeSection: HomeFeedSection
    @Binding var dynamicScope: DynamicFeedScope

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if selectedTab == .home {
                    FeedChromeToolbarContent(
                        tabs: Array(HomeFeedSection.allCases),
                        tabTitle: { $0.title },
                        selection: $homeSection
                    )
                }
                if selectedTab == .dynamic {
                    FeedChromeToolbarContent(
                        tabs: Array(DynamicFeedScope.allCases),
                        tabTitle: { $0.title },
                        selection: $dynamicScope
                    )
                }
            }
    }
}

struct ProfileView: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        ProfileRoot()
    }
}
