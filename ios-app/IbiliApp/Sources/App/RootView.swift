import SwiftUI
import UIKit

extension EnvironmentValues {
    var isInPlayerHostNavigation: Bool {
        get { self[IsInPlayerHostNavigationKey.self] }
        set { self[IsInPlayerHostNavigationKey.self] = newValue }
    }
}

private struct IsInPlayerHostNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

/// Top-level shell. Switches between login and main tab interface.
struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var router = DeepLinkRouter()
    @State private var retainsDismissedPlayerHost = false
    @State private var releaseDismissedPlayerHostWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Group {
                if session.isLoggedIn {
                    MainTabView()
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
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
            if router.pending != nil || retainsDismissedPlayerHost {
                DeepLinkPlayerHost(onRootDismissed: retainDismissedPlayerHost)
                    .environmentObject(router)
                    .tint(IbiliTheme.accent)
                    .zIndex(1)
            }
        }
        .environmentObject(router)
        .environment(\.openURL, OpenURLAction { url in
            router.handle(url)
        })
        .onChange(of: router.pending?.id) { newValue in
            guard newValue != nil else { return }
            releaseDismissedPlayerHostWork?.cancel()
            releaseDismissedPlayerHostWork = nil
            retainsDismissedPlayerHost = false
        }
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
    private static let hostReleaseGrace: TimeInterval = 0.28

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if let route = router.pending {
                    rootDestination(for: route)
                        .id(route.id)
                        .toolbar {
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
                } else {
                    Color.clear
                }
            }
            .navigationDestination(for: DeepLinkRouter.SessionRoute.self) { route in
                destinationView(for: route)
            }
        }
        .tint(.white)
        .environment(\.isInPlayerHostNavigation, true)
        .background(IbiliTheme.background)
        .offset(x: offsetX)
        .allowsHitTesting(!isRootDismissInFlight)
        .onAppear {
            cancelPendingDismiss()
            if router.pending != nil {
                isRootDismissInFlight = false
            }
            syncPlayerSessions()
            animateHostInIfNeeded(for: router.pending?.id)
        }
        .onChange(of: router.pending?.id) { newRouteID in
            cancelPendingDismiss()
            if newRouteID != nil {
                isRootDismissInFlight = false
                animateHostInIfNeeded(for: newRouteID)
            } else {
                animatedInRouteID = nil
            }
            syncPlayerSessions()
        }
        .onChange(of: router.path.map(\.id)) { _ in
            cancelPendingDismiss()
            if router.pending != nil {
                isRootDismissInFlight = false
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
            cancelPendingDismiss()
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
        withAnimation(Self.slideSpring) {
            offsetX = width
        }
        cancelPendingDismiss()
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

    private func cancelPendingDismiss() {
        pendingDismissWork?.cancel()
        pendingDismissWork = nil
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

    private func syncPlayerSessions() {
        PlayerRuntimeCoordinator.shared.retainSessions(root: router.pending?.playerRoute, stack: router.playerPath)
    }

    @ViewBuilder
    private func destinationView(for route: DeepLinkRouter.SessionRoute) -> some View {
        switch route {
        case .player(let playerRoute):
            playerDestination(for: playerRoute)
                .id(playerRoute.id)
        case .live(let liveRoute):
            liveDestination(for: liveRoute)
                .id(liveRoute.id)
        case .userSpace(let userSpaceRoute):
            UserSpaceView(mid: userSpaceRoute.mid)
        case .dynamicDetail(let detailRoute):
            DynamicDetailView(item: detailRoute.item)
        }
    }

    @ViewBuilder
    private func rootDestination(for route: DeepLinkRouter.RootRoute) -> some View {
        switch route {
        case .player(let playerRoute):
            playerDestination(for: playerRoute)
        case .live(let liveRoute):
            liveDestination(for: liveRoute)
        }
    }

    private func playerDestination(for route: DeepLinkRouter.PlayerRoute) -> some View {
        PlayerView(
            item: route.item,
            viewModel: PlayerRuntimeCoordinator.shared.viewModel(for: route.id),
            onPictureInPictureActiveChange: { isActive in
                handlePictureInPictureChange(isActive, routeID: route.id)
            },
            onPictureInPictureRestore: { completion in
                restorePictureInPicture(routeID: route.id, completion: completion)
            }
        )
        .tint(.white)
    }

    private func liveDestination(for route: DeepLinkRouter.LiveRoute) -> some View {
        LiveRoomView(route: route)
            .tint(.white)
    }

    private var isAnyAreaPlayerSwipeBackEnabled: Bool {
        guard router.pending != nil, !isRootDismissInFlight else { return false }
        return router.path.isEmpty
            || router.path.last?.playerRoute != nil
            || router.path.last?.liveRoute != nil
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
            if !isEnabled {
                hasBegunSwipe = false
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
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
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard velocity.x > 180 else { return false }
            return abs(velocity.x) > abs(velocity.y) * 1.35
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard parent.isEnabled else { return false }
            var view = touch.view
            while let current = view {
                if current is UIControl {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct MainTabView: View {
    var body: some View {
        // On iOS 18+ we use the new `Tab(role: .search)` initializer
        // so SwiftUI renders the search tab the way Apple Music does:
        // a separate magnifying-glass capsule next to the rest of the
        // tab bar that, when tapped, expands a long search field at
        // the bottom and collapses the other tabs into a single pill.
        // On iOS 16/17 we fall back to a plain extra `.tabItem`,
        // which still works but doesn't get the floating split look.
        if #available(iOS 18.0, *) {
            TabView {
                Tab("首页", systemImage: "house.fill") {
                    NavigationStack {
                        HomeView()
                    }
                }
                Tab("动态", systemImage: "sparkles") {
                    NavigationStack {
                        DynamicFeedView()
                    }
                }
                Tab("我的", systemImage: "person.crop.circle") {
                    NavigationStack {
                        ProfileView()
                    }
                }
                Tab(role: .search) {
                    SearchView()
                }
            }
            .tint(IbiliTheme.accent)
        } else {
            TabView {
                NavigationStack {
                    HomeView()
                }
                .tabItem { Label("首页", systemImage: "house.fill") }

                NavigationStack {
                    DynamicFeedView()
                }
                .tabItem { Label("动态", systemImage: "sparkles") }

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }

                NavigationStack {
                    ProfileView()
                }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
            }
            .tint(IbiliTheme.accent)
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        ProfileRoot()
    }
}
