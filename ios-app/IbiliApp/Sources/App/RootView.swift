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

/// Top-level shell. Switches between login and main tab interface.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject var session: AppSession
    @StateObject private var router = DeepLinkRouter()
    @State private var retainsDismissedPlayerHost = false
    @State private var releaseDismissedPlayerHostWork: DispatchWorkItem?
    @State private var splitDetailProgress: CGFloat = 0
    @State private var splitRootDismissWork: DispatchWorkItem?
    @State private var splitLayoutBaseSize: CGSize?

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
            router.handle(url)
        })
        .onChange(of: router.pending?.id) { newValue in
            guard newValue != nil else { return }
            splitRootDismissWork?.cancel()
            splitRootDismissWork = nil
            splitDetailProgress = 1
            releaseDismissedPlayerHostWork?.cancel()
            releaseDismissedPlayerHostWork = nil
            retainsDismissedPlayerHost = false
        }
        .onChange(of: session.isLoggedIn) { _ in
            splitDetailProgress = 0
            splitLayoutBaseSize = nil
        }
    }

    @ViewBuilder
    private func mainContent(size: CGSize, canSplit: Bool, usesSplit: Bool) -> some View {
        if canSplit {
            let splitMetrics = splitLayoutMetrics(size: size, usesSplit: usesSplit)
            ZStack(alignment: .leading) {
                MainTabView()
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
            MainTabView()
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
                  router.path.isEmpty else { return }
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
}

/// Wrapper that hosts the active player session. The router owns the
/// decision of whether a navigation creates the root layer, pushes a
/// new layer, or replaces the current layer.
private struct DeepLinkPlayerHost: View {
    @EnvironmentObject private var router: DeepLinkRouter
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
        NavigationStack(path: $router.path) {
            Group {
                if let route = router.pending {
                    rootDestination(for: route)
                        .id(route.id)
                        .environment(\.dismissPlayerHost, dismiss)
                        .toolbar { rootDismissToolbar(for: route) }
                } else {
                    Color.clear
                }
            }
            .navigationDestination(for: DeepLinkRouter.SessionRoute.self) { route in
                destinationView(for: route)
                    .environment(\.dismissPlayerHost, dismiss)
            }
        }
        .tint(.white)
        .environment(\.isInPlayerHostNavigation, true)
        .background(IbiliTheme.background)
        .offset(x: offsetX)
        .allowsHitTesting(!isRootDismissInFlight)
        .onAppear {
            cancelPendingDismiss(resetRouterDismissal: true)
            if router.pending != nil {
                isRootDismissInFlight = false
            }
            syncPlayerSessions()
            animateHostInIfNeeded(for: router.pending?.id)
            revealHostIfNeeded(reason: "appear")
        }
        .onChange(of: router.pending?.id) { newRouteID in
            cancelPendingDismiss(resetRouterDismissal: true)
            if newRouteID != nil {
                isRootDismissInFlight = false
                router.cancelRootSessionDismissal()
                animateHostInIfNeeded(for: newRouteID)
                revealHostIfNeeded(reason: "pending")
            } else {
                animatedInRouteID = nil
            }
            syncPlayerSessions()
        }
        .onChange(of: router.path.map(\.id)) { _ in
            cancelPendingDismiss(resetRouterDismissal: true)
            if router.pending != nil {
                isRootDismissInFlight = false
                router.cancelRootSessionDismissal()
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
        if !router.path.isEmpty {
            router.path.removeLast()
            return
        }
        let width = UIScreen.main.bounds.width
        isRootDismissInFlight = true
        prepareRootRouteForDismissal(router.pending)
        router.beginRootSessionDismissal()
        withAnimation(Self.slideSpring) {
            offsetX = width
        }
        cancelPendingDismiss(resetRouterDismissal: false)
        let dismissingRouteID = router.pending?.id
        let work = DispatchWorkItem {
            guard router.pending?.id == dismissingRouteID,
                  router.path.isEmpty else { return }
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
    private func rootDismissToolbar(for route: DeepLinkRouter.RootRoute) -> some ToolbarContent {
        if !route.usesOwnPlayerHostToolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
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
        PlayerRuntimeCoordinator.shared.retainSessions(root: router.pending?.playerRoute, stack: router.playerPath)
        LiveRuntimeCoordinator.shared.retainSessions(root: router.pending?.liveRoute, stack: router.livePath)
        AnimePlayerRuntimeCoordinator.shared.retainSessions(root: router.pending?.animePlayerRoute, stack: router.animePlayerPath)
    }

    private func prepareRootRouteForDismissal(_ route: DeepLinkRouter.RootRoute?) {
        switch route {
        case .player(let playerRoute):
            PlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: playerRoute.id)
        case .live(let liveRoute):
            LiveRuntimeCoordinator.shared.prepareForDismissal(routeID: liveRoute.id)
        case .animePlayer(let animeRoute):
            AnimePlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: animeRoute.id)
        case .dynamicDetail, .userSpace, .article, .search, .animeSubject, nil:
            break
        }
    }

    @ViewBuilder
    private func destinationView(for route: DeepLinkRouter.SessionRoute) -> some View {
        DeepLinkRouteContent.destinationView(
            for: route,
            onPictureInPictureActiveChange: handlePictureInPictureChange,
            onPictureInPictureRestore: restorePictureInPicture
        )
    }

    @ViewBuilder
    private func rootDestination(for route: DeepLinkRouter.RootRoute) -> some View {
        DeepLinkRouteContent.rootDestination(
            for: route,
            onPictureInPictureActiveChange: handlePictureInPictureChange,
            onPictureInPictureRestore: restorePictureInPicture
        )
    }

    private var isAnyAreaPlayerSwipeBackEnabled: Bool {
        guard router.pending != nil, !isRootDismissInFlight else { return false }
        guard !Orientation.isAVKitFullscreenVisible() else { return false }
        return router.path.isEmpty
            || router.path.last?.playerRoute != nil
            || router.path.last?.liveRoute != nil
            || router.path.last?.animePlayerRoute != nil
    }

    private func handleAnyAreaSwipeBackChanged(_ translationX: CGFloat) {
        guard isAnyAreaPlayerSwipeBackEnabled else { return }
        guard router.path.isEmpty else { return }
        offsetX = min(max(translationX, 0), UIScreen.main.bounds.width)
    }

    private func handleAnyAreaSwipeBackEnded(translationX: CGFloat, velocityX: CGFloat) {
        guard isAnyAreaPlayerSwipeBackEnabled else {
            handleAnyAreaSwipeBackCancelled()
            return
        }
        if translationX > 80 || velocityX > 650 {
            dismiss()
        } else {
            handleAnyAreaSwipeBackCancelled()
        }
    }

    private func handleAnyAreaSwipeBackCancelled() {
        guard router.path.isEmpty else { return }
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
}

private struct DeepLinkRouteContent {
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
        case .live(let liveRoute):
            liveDestination(for: liveRoute)
                .id(liveRoute.id)
        case .userSpace(let userSpaceRoute):
            UserSpaceView(mid: userSpaceRoute.mid)
        case .dynamicDetail(let detailRoute):
            DynamicDetailView(item: detailRoute.item)
        case .article(let articleRoute):
            ArticleView(articleID: articleRoute.articleID, kind: articleRoute.kind)
        case .search(let searchRoute):
            SearchRouteView(keyword: searchRoute.keyword)
        case .animeSubject(let animeRoute):
            AnimeSubjectView(subjectID: animeRoute.subjectID, initialSubject: animeRoute.initialSubject)
        case .animePlayer(let animeRoute):
            animeDestination(for: animeRoute)
        }
    }

    @ViewBuilder
    @MainActor
    static func rootDestination(
        for route: DeepLinkRouter.RootRoute,
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
        case .live(let liveRoute):
            liveDestination(for: liveRoute)
        case .dynamicDetail(let detailRoute):
            DynamicDetailView(item: detailRoute.item)
        case .userSpace(let userSpaceRoute):
            UserSpaceView(mid: userSpaceRoute.mid)
        case .article(let articleRoute):
            ArticleView(articleID: articleRoute.articleID, kind: articleRoute.kind)
        case .search(let searchRoute):
            SearchRouteView(keyword: searchRoute.keyword)
        case .animeSubject(let animeRoute):
            AnimeSubjectView(subjectID: animeRoute.subjectID, initialSubject: animeRoute.initialSubject)
        case .animePlayer(let animeRoute):
            animeDestination(for: animeRoute)
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

    @MainActor
    static func animeDestination(for route: DeepLinkRouter.AnimePlayerRoute) -> some View {
        AnimePlayerView(
            route: route,
            viewModel: AnimePlayerRuntimeCoordinator.shared.viewModel(for: route.id)
        )
        .tint(.white)
    }
}

struct InlinePlayerRouteDestination: View {
    let route: DeepLinkRouter.PlayerRoute

    var body: some View {
        PlayerView(
            item: route.item,
            offlineOnly: route.offlineOnly,
            viewModel: PlayerRuntimeCoordinator.shared.viewModel(for: route.id)
        )
        .id(route.id)
        .tint(.white)
        .toolbar(.hidden, for: .tabBar)
        .environment(\.isInPlayerHostNavigation, true)
    }
}

private struct DeepLinkSplitHost: View {
    @EnvironmentObject private var router: DeepLinkRouter
    let onRootDismiss: () -> Void

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if let route = router.pending {
                    DeepLinkRouteContent.rootDestination(
                        for: route,
                        onPictureInPictureActiveChange: handlePictureInPictureChange,
                        onPictureInPictureRestore: restorePictureInPicture
                    )
                    .id(route.id)
                    .environment(\.dismissPlayerHost, dismiss)
                    .toolbar { rootDismissToolbar(for: route) }
                } else {
                    splitEmptyState
                }
            }
            .navigationDestination(for: DeepLinkRouter.SessionRoute.self) { route in
                DeepLinkRouteContent.destinationView(
                    for: route,
                    onPictureInPictureActiveChange: handlePictureInPictureChange,
                    onPictureInPictureRestore: restorePictureInPicture
                )
                .environment(\.dismissPlayerHost, dismiss)
            }
        }
        .tint(.white)
        .environment(\.isInPlayerHostNavigation, true)
        .environment(\.prefersSplitRootSelection, false)
        .environment(\.splitRootIsActive, true)
        .background(IbiliTheme.background)
        .onAppear { syncPlayerSessions() }
        .onChange(of: router.pending?.id) { _ in
            router.cancelRootSessionDismissal()
            syncPlayerSessions()
        }
        .onChange(of: router.path.map(\.id)) { _ in
            router.cancelRootSessionDismissal()
            syncPlayerSessions()
        }
        .onDisappear {
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
        if !router.path.isEmpty {
            router.path.removeLast()
            return
        }
        prepareRootRouteForDismissal(router.pending)
        onRootDismiss()
    }

    @ToolbarContentBuilder
    private func rootDismissToolbar(for route: DeepLinkRouter.RootRoute) -> some ToolbarContent {
        if !route.usesOwnPlayerHostToolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: router.path.isEmpty ? "xmark" : "chevron.backward")
                        .fontWeight(.semibold)
                }
                .tint(.white)
            }
        }
    }

    private func syncPlayerSessions() {
        PlayerRuntimeCoordinator.shared.retainSessions(root: router.pending?.playerRoute, stack: router.playerPath)
        LiveRuntimeCoordinator.shared.retainSessions(root: router.pending?.liveRoute, stack: router.livePath)
        AnimePlayerRuntimeCoordinator.shared.retainSessions(root: router.pending?.animePlayerRoute, stack: router.animePlayerPath)
    }

    private func prepareRootRouteForDismissal(_ route: DeepLinkRouter.RootRoute?) {
        switch route {
        case .player(let playerRoute):
            PlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: playerRoute.id)
        case .live(let liveRoute):
            LiveRuntimeCoordinator.shared.prepareForDismissal(routeID: liveRoute.id)
        case .animePlayer(let animeRoute):
            AnimePlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: animeRoute.id)
        case .dynamicDetail, .userSpace, .article, .search, .animeSubject, nil:
            break
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
            // Keep the recognizer itself alive while AVKit fullscreen or
            // modal shields are active. Toggling `isEnabled` off here can
            // leave the window-level recognizer disabled if fullscreen exits
            // without a SwiftUI update pass; the delegate below performs the
            // transient gating at gesture-begin time instead.
            pan?.isEnabled = isEnabled
            if !isEnabled || ModalGestureShield.isActive || Orientation.isAVKitFullscreenVisible() {
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
                  !Orientation.isAVKitFullscreenVisible(),
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
                  !ModalGestureShield.isActive,
                  !Orientation.isAVKitFullscreenVisible() else { return false }
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

struct MainTabView: View {
    @State private var selectedTab: MainTab = .home
    @StateObject private var tabReselect = TabReselectSignals()
    @EnvironmentObject private var settings: AppSettings

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
                    NavigationStack {
                        HomeView()
                    }
                }
                Tab("动态", systemImage: "sparkles", value: MainTab.dynamic) {
                    NavigationStack {
                        DynamicFeedView()
                    }
                }
                if settings.animeTrackingEnabled {
                    Tab("追番", systemImage: "play.tv.fill", value: MainTab.anime) {
                        NavigationStack {
                            AnimeHomeView()
                        }
                    }
                }
                Tab("我的", systemImage: "person.crop.circle", value: MainTab.profile) {
                    NavigationStack {
                        ProfileView()
                    }
                }
                Tab(value: MainTab.search, role: .search) {
                    SearchView()
                }
            }
            .tint(IbiliTheme.accent)
            .tabViewStyle(.tabBarOnly)
            .toolbarBackground(.hidden, for: .tabBar)
            .environmentObject(tabReselect)
            .background(tabReselectObserver(order: [.home, .dynamic] + (settings.animeTrackingEnabled ? [.anime] : []) + [.profile, .search]))
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    HomeView()
                }
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(MainTab.home)

                NavigationStack {
                    DynamicFeedView()
                }
                .tabItem { Label("动态", systemImage: "sparkles") }
                .tag(MainTab.dynamic)

                if settings.animeTrackingEnabled {
                    NavigationStack {
                        AnimeHomeView()
                    }
                    .tabItem { Label("追番", systemImage: "play.tv.fill") }
                    .tag(MainTab.anime)
                }

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(MainTab.search)

                NavigationStack {
                    ProfileView()
                }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(MainTab.profile)
            }
            .tint(IbiliTheme.accent)
            .toolbarBackground(.hidden, for: .tabBar)
            .environmentObject(tabReselect)
            .background(tabReselectObserver(order: [.home, .dynamic] + (settings.animeTrackingEnabled ? [.anime] : []) + [.search, .profile]))
        }
    }

    private func tabReselectObserver(order: [MainTab]) -> some View {
        TabBarReselectObserver(
            selectedTab: selectedTab,
            orderedTabs: order,
            onReselect: { tab in
                switch tab {
                case .home:
                    tabReselect.triggerHome()
                case .dynamic:
                    tabReselect.triggerDynamic()
                case .anime:
                    tabReselect.triggerAnime()
                case .search:
                    tabReselect.triggerSearch()
                case .profile:
                    tabReselect.triggerProfile()
                }
            }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private enum MainTab: Hashable {
        case home
        case dynamic
        case anime
        case profile
        case search
    }
}

struct ProfileView: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        ProfileRoot()
    }
}
