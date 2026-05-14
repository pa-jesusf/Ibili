import SwiftUI

enum AnimeCollectionKind: Int64, CaseIterable, Identifiable {
    case doing = 3
    case wish = 1
    case done = 2
    case onHold = 4
    case dropped = 5

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .doing: return "在看"
        case .wish: return "想看"
        case .done: return "看过"
        case .onHold: return "搁置"
        case .dropped: return "抛弃"
        }
    }
}

struct AnimeHomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = AnimeHomeViewModel()
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @State private var selectedKind: AnimeCollectionKind = .doing
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showsSourceSheet = false
    @State private var showsLogoutConfirmation = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                accountSection
                controlsSection
                if !vm.searchResults.isEmpty || isSearching {
                    searchResultsSection
                }
                collectionSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(IbiliTheme.background)
        .navigationTitle("追番")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsSourceSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .task {
            await sourceStore.ensureDefaultSubscriptionsLoaded()
        }
        .task(id: session.bangumiUser?.username ?? "") {
            await session.refreshBangumiIfNeeded(
                clientID: BangumiOAuthConfig.clientID,
                clientSecret: BangumiOAuthConfig.clientSecret
            )
            await vm.load(kind: selectedKind, session: session)
        }
        .refreshable {
            await vm.load(kind: selectedKind, session: session, force: true)
        }
        .sheet(isPresented: $showsSourceSheet) {
            NavigationStack {
                AnimeSourceSettingsView(store: sourceStore)
            }
        }
        .confirmationDialog("退出 Bangumi？", isPresented: $showsLogoutConfirmation, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                session.logoutBangumi()
                vm.items = []
                vm.searchResults = []
            }
            Button("取消", role: .cancel) {}
        }
        .tint(IbiliTheme.accent)
    }

    private var accountSection: some View {
        Group {
            if let user = session.bangumiUser {
                HStack(spacing: 12) {
                    RemoteImage(url: user.avatar, targetPointSize: CGSize(width: 96, height: 96), quality: 82)
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.nickname.isEmpty ? user.username : user.nickname)
                            .font(.headline)
                            .foregroundStyle(IbiliTheme.textPrimary)
                        Text("@\(user.username)")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    Spacer()
                    Button {
                        showsLogoutConfirmation = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(IbiliTheme.textSecondary)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.key.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(IbiliTheme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("登录 Bangumi")
                            .font(.headline)
                            .foregroundStyle(IbiliTheme.textPrimary)
                        Text(oauthHint)
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("登录") { startOAuth() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IbiliTheme.surface))
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IbiliSectionHeader(title: "添加条目", systemImage: "magnifyingglass", iconColor: IbiliTheme.accent) {
                Button {
                    showsSourceSheet = true
                } label: {
                    Label(sourceSummaryText, systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(IbiliTheme.textSecondary)
                TextField("搜索 Bangumi 条目", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        vm.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { await search() }
                } label: {
                    Text("搜索")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            IbiliSectionHeader(title: "搜索结果", systemImage: "plus.circle", iconColor: IbiliTheme.accent)
            ForEach(vm.searchResults) { subject in
                Button {
                    router.openAnimeSubject(subject)
                } label: {
                    AnimeSubjectRow(subject: subject, subtitle: subject.date)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IbiliSectionHeader(title: "我的收藏", systemImage: "play.tv", iconColor: IbiliTheme.accent)
            Picker("分组", selection: $selectedKind) {
                ForEach(AnimeCollectionKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedKind) { kind in
                Task { await vm.load(kind: kind, session: session, force: true) }
            }

            if session.bangumiUser == nil {
                emptyState(
                    title: "需要 Bangumi 登录",
                    symbol: "person.crop.circle.badge.exclamationmark",
                    message: "登录后会同步你的在看、想看、看过等分组。"
                )
                .padding(.vertical, 24)
            } else if vm.isLoading && vm.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if vm.items.isEmpty {
                emptyState(
                    title: "\(selectedKind.title)为空",
                    symbol: "play.tv",
                    message: "可以通过上方搜索添加新条目。"
                )
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(vm.items) { item in
                        Button {
                            router.openAnimeSubject(item.subject)
                        } label: {
                            AnimeSubjectRow(
                                subject: item.subject,
                                subtitle: "\(item.collectionLabel) · 已看 \(item.epStatus)/\(max(item.subject.totalEpisodes, 0))"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if vm.hasMore {
                        Button {
                            Task { await vm.loadMore(kind: selectedKind, session: session) }
                        } label: {
                            HStack {
                                if vm.isLoading {
                                    ProgressView().controlSize(.small)
                                }
                                Text(vm.isLoading ? "加载中" : "加载更多")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isLoading)
                    }
                }
            }
        }
    }

    private var oauthHint: String {
        "使用 Bangumi OAuth 维护收藏和单集看过状态。"
    }

    private var sourceSummaryText: String {
        let enabled = sourceStore.sources.filter(\.enabled).count
        return sourceStore.sources.isEmpty ? "规则源" : "\(enabled)/\(sourceStore.sources.count)"
    }

    private func startOAuth() {
        Task {
            do {
                let url = try await session.startBangumiOAuth(
                    clientID: BangumiOAuthConfig.clientID,
                    redirectURI: BangumiOAuthConfig.redirectURI
                )
                openURL(url)
            } catch {
                vm.errorText = error.localizedDescription
            }
        }
    }

    private func search() async {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        await vm.search(keyword: keyword)
    }
}

@MainActor
final class AnimeHomeViewModel: ObservableObject {
    @Published var items: [AnimeCollectionItemDTO] = []
    @Published var searchResults: [AnimeSubjectDTO] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private var page: Int64 = 1
    private var total: Int64 = 0
    private let pageSize: Int64 = 20

    var hasMore: Bool {
        Int64(items.count) < total
    }

    func load(kind: AnimeCollectionKind, session: AppSession, force: Bool = false) async {
        guard let user = session.bangumiUser else {
            items = []
            total = 0
            return
        }
        if isLoading { return }
        if !force, !items.isEmpty { return }
        page = 1
        isLoading = true
        defer { isLoading = false }
        do {
            let accessToken = session.bangumiAccessToken
            let username = user.username
            let collectionType = kind.rawValue
            let pageSize = self.pageSize
            let result = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeCollectionList(
                    accessToken: accessToken,
                    username: username,
                    collectionType: collectionType,
                    page: 1,
                    pageSize: pageSize
                )
            }.value
            items = result.items
            total = result.total
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func loadMore(kind: AnimeCollectionKind, session: AppSession) async {
        guard let user = session.bangumiUser, hasMore, !isLoading else { return }
        let nextPage = page + 1
        isLoading = true
        defer { isLoading = false }
        do {
            let accessToken = session.bangumiAccessToken
            let username = user.username
            let collectionType = kind.rawValue
            let pageSize = self.pageSize
            let result = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeCollectionList(
                    accessToken: accessToken,
                    username: username,
                    collectionType: collectionType,
                    page: nextPage,
                    pageSize: pageSize
                )
            }.value
            page = nextPage
            items.append(contentsOf: result.items)
            total = result.total
        } catch {
            errorText = error.localizedDescription
        }
    }

    func search(keyword: String) async {
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeSubjectSearch(keyword: keyword)
            }.value
            searchResults = result.items
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct AnimeSubjectRow: View {
    let subject: AnimeSubjectDTO
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: subject.coverURL, targetPointSize: CGSize(width: 112, height: 150), quality: 82)
                .frame(width: 56, height: 75)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(subject.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                Text([subtitle, scoreText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
                if !subject.summary.isEmpty {
                    Text(subject.summary)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IbiliTheme.textSecondary)
        }
        .padding(10)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var scoreText: String {
        subject.ratingScore > 0 ? String(format: "%.1f", subject.ratingScore) : ""
    }
}

private struct AnimeSourceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var store: AnimeSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var importText = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @FocusState private var importEditorFocused: Bool

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await refreshDefaultSubscriptions() }
                } label: {
                    HStack {
                        Text("刷新默认订阅源")
                        Spacer()
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isLoading)
                LabeledContent("默认订阅") {
                    Text("bt1 + css1")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            } header: {
                Text("默认源")
            } footer: {
                Text("与 animeko 默认订阅源一致。BT/磁力资源第一版会显示为暂不支持，可播放的 HLS/MP4 会正常进入播放器。")
            }

            Section {
                TextField("订阅 URL", text: $settings.animeSourceSubscriptionURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await updateSubscription() }
                } label: {
                    HStack {
                        Text("刷新订阅")
                        Spacer()
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isLoading || settings.animeSourceSubscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("自定义订阅")
            }

            Section {
                TextEditor(text: $importText)
                    .frame(minHeight: 120)
                    .focused($importEditorFocused)
                Button("导入 JSON") {
                    Task { await importJSON() }
                }
                .disabled(isLoading || importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("手动导入")
            }

            Section {
                if store.sources.isEmpty {
                    Text("暂无规则源")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.sources) { source in
                        Toggle(isOn: Binding(
                            get: { source.enabled },
                            set: { store.setEnabled($0, for: source) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .foregroundStyle(IbiliTheme.textPrimary)
                                Text(sourceDescription(source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("来源")
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("规则源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { importEditorFocused = false }
            }
        }
    }

    private func updateSubscription() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.updateSubscription(url: settings.animeSourceSubscriptionURL)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshDefaultSubscriptions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.refreshDefaultSubscriptions()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importJSON() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.importJSON(importText)
            importText = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func sourceDescription(_ source: AnimeSourceDTO) -> String {
        let type = source.factoryID == "rss" ? "RSS" : "Web Selector"
        return source.description.isEmpty ? type : "\(type) · \(source.description)"
    }
}
