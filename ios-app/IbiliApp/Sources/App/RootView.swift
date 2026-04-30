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

/// Wrapper that hosts the active `PlayerView` and listens to the
/// router so taps on related videos *replace* the current player
/// rather than stacking. Re-keying via `.id(...)` is what gives us
/// the "replace, don't stack" behaviour requested by the user.
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
        NavigationStack {
            Group {
                if let item = router.pending {
                    PlayerView(item: item)
                        .id("\(item.aid):\(item.bvid)")
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
        }
        .background(IbiliTheme.background)
        .offset(x: offsetX)
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
        // We only consume drags that *start* within the first ~16pt
        // so it never fights vertical scroll views or horizontal
        // carousels inside the player content.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            guard v.translation.width > 0,
                                  abs(v.translation.width) > abs(v.translation.height) else {
                                return
                            }
                            // Track the finger directly, no
                            // animation — the per-frame offset
                            // assignment is what actually runs the
                            // 120 Hz draw loop while the user drags.
                            offsetX = v.translation.width
                        }
                        .onEnded { v in
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
                )
        }
    }

    /// Slide off-screen, then drop the routed item. Splitting the
    /// "animate offset out" from the "clear pending" steps means
    /// the host's removal isn't tied to a SwiftUI insertion/removal
    /// transition — there's only ever a single offset animation in
    /// flight, which keeps the path on ProMotion's 120 Hz cadence.
    private func dismiss() {
        let width = UIScreen.main.bounds.width
        withAnimation(Self.slideSpring) {
            offsetX = width
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            router.pending = nil
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
                            .navigationTitle("推荐")
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
        List {
            Section("账户") {
                LabeledContent("UID", value: String(session.mid))
            }
            Section("偏好") {
                NavigationLink {
                    SettingsView()
                } label: {
                    profileRowLabel("设置", systemImage: "rectangle.grid.2x2")
                }
            }
            Section("诊断") {
                NavigationLink {
                    LogsView()
                } label: {
                    profileRowLabel("应用日志", systemImage: "doc.text.magnifyingglass")
                }
            }
            Section {
                Button(role: .destructive) {
                    session.logout()
                } label: {
                    Text("退出登录").frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        // Re-assert the accent tint at the List level so the row
        // icons stay pink after pushing a detail view and popping back.
        // SwiftUI's TabView-level `.tint` occasionally fails to
        // propagate into NavigationStack content on push/pop, which
        // would otherwise let the system's default blue tint bleed
        // through into Label icons.
        .tint(IbiliTheme.accent)
    }

    private func profileRowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(IbiliTheme.accent)
        }
    }
}
