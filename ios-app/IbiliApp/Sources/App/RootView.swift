import SwiftUI

/// Top-level shell. Switches between login and main tab interface.
struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var router = DeepLinkRouter()

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
            if router.pending != nil {
                DeepLinkPlayerHost()
                    .environmentObject(router)
                    .tint(IbiliTheme.accent)
                    .zIndex(1)
            }
        }
        .environmentObject(router)
        .environment(\.openURL, OpenURLAction { url in
            router.handle(url)
        })
    }
}

/// Wrapper that hosts the active player session. The router owns the
/// decision of whether a navigation creates the root layer, pushes a
/// new layer, or replaces the current layer.
private struct DeepLinkPlayerHost: View {
    @EnvironmentObject private var router: DeepLinkRouter
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
    /// Tri-state lock for the leading-edge drag. `undecided` while
    /// we're still reading the slope of the user's motion; once we
    /// commit to either `.horizontal` (swipe-back) or `.vertical`
    /// (the user is actually scrolling the page underneath), we
    /// stay there for the rest of the drag. Resets in `onEnded`.
    @State private var dragDecision: DragDecision = .undecided

    private enum DragDecision { case undecided, horizontal, vertical }

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

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if let route = router.pending {
                    PlayerView(
                        item: route.item,
                        viewModel: PlayerSessionStore.shared.viewModel(for: route.id),
                        onPictureInPictureActiveChange: { isActive in
                            handlePictureInPictureChange(isActive, routeID: route.id)
                        },
                        onPictureInPictureRestore: { completion in
                            restorePictureInPicture(routeID: route.id, completion: completion)
                        }
                    )
                        .id(route.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    dismiss()
                                } label: {
                                    Image(systemName: "chevron.backward")
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                } else {
                    Color.clear
                }
            }
            .navigationDestination(for: DeepLinkRouter.PlayerRoute.self) { route in
                PlayerView(
                    item: route.item,
                    viewModel: PlayerSessionStore.shared.viewModel(for: route.id),
                    onPictureInPictureActiveChange: { isActive in
                        handlePictureInPictureChange(isActive, routeID: route.id)
                    },
                    onPictureInPictureRestore: { completion in
                        restorePictureInPicture(routeID: route.id, completion: completion)
                    }
                )
                    .id(route.id)
            }
        }
        .background(IbiliTheme.background)
        .offset(x: offsetX)
        .onAppear {
            syncPlayerSessions()
        }
        .onChange(of: router.pending?.id) { _ in
            syncPlayerSessions()
        }
        .onChange(of: router.path.map(\.id)) { _ in
            syncPlayerSessions()
        }
        .onAppear {
            // Start off-screen, then animate in. Doing it in
            // `onAppear` (rather than via a parent `.transition`)
            // means the slide is driven by exactly one offset
            // animation, which keeps the frame budget free for
            // 120 Hz.
            offsetX = UIScreen.main.bounds.width
            withAnimation(Self.slideSpring) {
                offsetX = 0
            }
        }
        // Restore the iOS interactive-pop gesture by hosting an
        // invisible DragGesture region pinned to the leading edge.
        //
        // IMPORTANT: this overlay only operates at the root layer
        // (`router.path.isEmpty`). When the user has pushed deeper
        // (related-video tap / season episode), the inner
        // `NavigationStack` provides its own
        // `UIScreenEdgePanGestureRecognizer`-driven interactive
        // pop, which would otherwise be shadowed by this overlay
        // and cause the swipe to incorrectly tear the whole
        // session down.
        //
        // Industry consensus for "swipe-back vs vertical scroll":
        //   1. Generous edge zone (~20pt) so the gesture is easy to
        //      *start*, matching UIKit's `interactivePopGestureRecognizer`.
        //   2. A short undecided phase: read the first ~10pt of
        //      motion before committing. If vertical dominates,
        //      lock the gesture to `.vertical` and stop tracking
        //      (the user is scrolling the description / comments).
        //      If horizontal-positive dominates by ≥1.5×, lock to
        //      `.horizontal` and start tracking the offset. The
        //      slope ratio of 1.5 is what Apple uses internally for
        //      `UIScrollView.directionalLockEnabled` and what most
        //      well-behaved apps converge on.
        //   3. Once locked, never revisit the decision — prevents
        //      mid-drag jitter from re-capturing scroll input.
        .overlay(alignment: .leading) {
            if router.path.isEmpty {
                Color.clear
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .gesture(rootSwipeBackGesture)
            }
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
        withAnimation(Self.slideSpring) {
            offsetX = width
        }
        // Defer the heavy session teardown to a later runloop tick so
        // SwiftUI commits the slide animation before AVPlayer /
        // local-HLS / danmaku-displaylink deinit work seizes the main
        // thread. By the time the teardown runs, the host is already
        // off-screen, so the user never sees the freeze.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            router.closeSession()
        }
    }

    private func syncPlayerSessions() {
        PlayerSessionStore.shared.retainSessions(root: router.pending, stack: router.path)
    }

    private var rootSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let dx = v.translation.width
                let dy = v.translation.height
                switch dragDecision {
                case .vertical:
                    return
                case .horizontal:
                    if dx > 0 { offsetX = dx }
                case .undecided:
                    let ax = abs(dx), ay = abs(dy)
                    guard max(ax, ay) > 8 else { return }
                    if ay > ax {
                        dragDecision = .vertical
                    } else if dx > 0 && ax > ay * 1.5 {
                        dragDecision = .horizontal
                        offsetX = dx
                    } else {
                        dragDecision = .vertical
                    }
                }
            }
            .onEnded { v in
                defer { dragDecision = .undecided }
                guard dragDecision == .horizontal else { return }
                let dx = v.translation.width
                let vx = v.predictedEndTranslation.width
                if dx > 80 || vx > 200 {
                    dismiss()
                } else {
                    withAnimation(Self.slideSpring) {
                        offsetX = 0
                    }
                }
            }
    }

    private func handlePictureInPictureChange(_ isActive: Bool, routeID: UUID) {
        PlayerSessionStore.shared.setPictureInPictureActive(
            isActive,
            for: routeID,
            snapshot: isActive ? router.snapshot : nil
        )
        syncPlayerSessions()
    }

    private func restorePictureInPicture(routeID: UUID,
                                         completion: @escaping (Bool) -> Void) {
        if let snapshot = PlayerSessionStore.shared.pictureInPictureSnapshot(for: routeID) {
            router.restore(snapshot)
            syncPlayerSessions()
            completion(true)
            return
        }
        completion(router.containsRoute(id: routeID))
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
                            .navigationTitle("推荐")
                    }
                }
                Tab("动态", systemImage: "sparkles") {
                    NavigationStack {
                        DynamicFeedView()
                            .navigationTitle("动态")
                    }
                }
                Tab("我的", systemImage: "person.crop.circle") {
                    NavigationStack {
                        ProfileView()
                            .navigationTitle("我的")
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
                        .navigationTitle("推荐")
                }
                .tabItem { Label("首页", systemImage: "house.fill") }

                NavigationStack {
                    DynamicFeedView()
                        .navigationTitle("动态")
                }
                .tabItem { Label("动态", systemImage: "sparkles") }

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }

                NavigationStack {
                    ProfileView()
                        .navigationTitle("我的")
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
