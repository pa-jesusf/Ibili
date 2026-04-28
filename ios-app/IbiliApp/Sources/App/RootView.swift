import SwiftUI

/// Top-level shell. Switches between login and main tab interface.
struct RootView: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        if session.isLoggedIn {
            MainTabView()
                .transition(.opacity)
        } else {
            LoginView()
                .transition(.opacity)
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
                    .navigationTitle("推荐")
            }
            .tabItem { Label("首页", systemImage: "house.fill") }

            NavigationStack {
                ProfileView()
                    .navigationTitle("我的")
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(IbiliTheme.accent)
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
                    Label("显示设置", systemImage: "rectangle.grid.2x2")
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
    }
}
