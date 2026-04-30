import SwiftUI

/// Top-level shell. Switches between login and main tab interface.
struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var router = DeepLinkRouter()

    var body: some View {
        Group {
            if session.isLoggedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .environmentObject(router)
        .environment(\.openURL, OpenURLAction { url in
            router.handle(url)
        })
        .fullScreenCover(isPresented: Binding(
            get: { router.pending != nil },
            set: { if !$0 { router.pending = nil } }
        )) {
            // Host the player inside a wrapper that observes the router
            // directly. When `router.pending` changes (e.g. user tapped
            // a related video) we re-key on the aid so SwiftUI tears
            // down the previous player and mounts a fresh one — that
            // way back-from-related goes straight to the home tab
            // instead of stacking covers and creating a 套娃 chain.
            DeepLinkPlayerHost()
                .environmentObject(router)
                .tint(IbiliTheme.accent)
        }
    }
}

/// Wrapper inside the root `.fullScreenCover` that swaps its `PlayerView`
/// whenever `DeepLinkRouter.pending` changes — including taps on related
/// videos from inside the player. Re-keying via `.id(...)` is what gives
/// us the "replace, don't stack" behaviour requested by the user.
private struct DeepLinkPlayerHost: View {
    @EnvironmentObject private var router: DeepLinkRouter
    /// Live drag offset — set while the user pans from the leading
    /// edge so we can mirror the iOS "swipe-to-pop" parallax / fade.
    @State private var swipeOffsetX: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                if let item = router.pending {
                    PlayerView(item: item)
                        .id("\(item.aid):\(item.bvid)")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    router.pending = nil
                                } label: {
                                    // Back-arrow rather than dismiss-X
                                    // since this presentation supports an
                                    // edge-swipe-to-dismiss gesture below
                                    // and reads as a navigation pop, not
                                    // a modal dismissal.
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
        .offset(x: swipeOffsetX)
        // Restore the iOS interactive-pop gesture by hosting an
        // invisible DragGesture region pinned to the leading edge. We
        // only consume drags that *start* within the first ~16pt so it
        // never fights vertical scroll views or horizontal carousels
        // inside the player content.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            // Only follow if the gesture is dominantly
                            // horizontal & rightward.
                            guard v.translation.width > 0,
                                  abs(v.translation.width) > abs(v.translation.height) else {
                                return
                            }
                            swipeOffsetX = v.translation.width
                        }
                        .onEnded { v in
                            let dx = v.translation.width
                            let vx = v.predictedEndTranslation.width
                            if dx > 80 || vx > 200 {
                                // Commit dismiss — animate the host off
                                // the trailing edge before clearing the
                                // router pending so the cover unwinds.
                                withAnimation(.easeOut(duration: 0.18)) {
                                    swipeOffsetX = 1200
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                    router.pending = nil
                                    swipeOffsetX = 0
                                }
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    swipeOffsetX = 0
                                }
                            }
                        }
                )
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
                    profileRowLabel("显示设置", systemImage: "rectangle.grid.2x2")
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
