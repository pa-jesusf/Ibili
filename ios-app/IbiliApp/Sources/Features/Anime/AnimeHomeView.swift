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

private enum AnimeHomeSection: String, CaseIterable, Identifiable {
    case collection
    case explore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collection: return "收藏"
        case .explore: return "探索"
        }
    }
}

struct AnimeHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var tabReselect: TabReselectSignals
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @StateObject private var vm = AnimeHomeViewModel()
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @State private var section: AnimeHomeSection = .collection
    @State private var selectedKind: AnimeCollectionKind = .doing
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showsSourceSheet = false
    @State private var showsLogoutConfirmation = false
    @State private var headerCollapseProgress: CGFloat = 0
    @State private var switcherCollapseProgress: CGFloat = 0

    var body: some View {
        FeedChrome(
            title: "追番",
            tabs: Array(AnimeHomeSection.allCases),
            tabTitle: { $0.title },
            selection: $section,
            headerCollapseProgress: $headerCollapseProgress,
            switcherCollapseProgress: $switcherCollapseProgress
        ) {
            content
        }
            .sheet(isPresented: $showsSourceSheet) {
                SheetScaffold(title: "数据源") {
                    AnimeSourceSettingsView(store: sourceStore, showsDoneButton: false)
                }
                .environmentObject(settings)
            }
            .confirmationDialog("退出 Bangumi？", isPresented: $showsLogoutConfirmation, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    session.logoutBangumi()
                    vm.resetCollection()
                    vm.searchResults = []
                }
                Button("取消", role: .cancel) {}
            }
            .task {
                await sourceStore.ensureDefaultSubscriptionsLoaded()
            }
            .task(id: session.bangumiUser?.username ?? "") {
                await session.refreshBangumiIfNeeded(
                    clientID: BangumiOAuthConfig.clientID,
                    clientSecret: BangumiOAuthConfig.clientSecret
                )
                await vm.load(kind: selectedKind, session: session, force: true)
            }
            .onChange(of: section) { _ in
                headerCollapseProgress = 0
                switcherCollapseProgress = 0
            }
            .tint(IbiliTheme.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .collection:
            collectionPage
        case .explore:
            explorePage
        }
    }

    private var collectionPage: some View {
        GeometryReader { geo in
            FeedScrollPage(
                title: "追番",
                coordinateSpace: "anime-collection-scroll",
                scrollToTopSignal: tabReselect.anime,
                headerCollapseProgress: $headerCollapseProgress,
                switcherCollapseProgress: $switcherCollapseProgress,
                showsRefresh: true,
                onRefresh: {
                    await vm.load(kind: selectedKind, session: session, force: true)
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    accountSection
                    Picker("分组", selection: $selectedKind) {
                        ForEach(AnimeCollectionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedKind) { kind in
                        Task { await vm.load(kind: kind, session: session, force: true) }
                    }

                    collectionContent(cardWidth: max(1, geo.size.width - 24))
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
    }

    private var explorePage: some View {
        GeometryReader { geo in
            FeedScrollPage(
                title: "追番",
                coordinateSpace: "anime-explore-scroll",
                scrollToTopSignal: tabReselect.anime,
                headerCollapseProgress: $headerCollapseProgress,
                switcherCollapseProgress: $switcherCollapseProgress
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    searchBar
                    if let errorText = vm.errorText, !errorText.isEmpty, vm.searchResults.isEmpty {
                        emptyState(title: "搜索失败", symbol: "wifi.exclamationmark", message: errorText)
                            .padding(.top, 40)
                    } else if isSearching {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if vm.searchResults.isEmpty {
                        emptyState(title: "搜索 Bangumi 条目", symbol: "magnifyingglass")
                            .padding(.top, 52)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(vm.searchResults) { subject in
                                animeCardButton(subject: subject, cardWidth: max(1, geo.size.width - 24), style: .detailed)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
    }

    private var accountSection: some View {
        Group {
            if let user = session.bangumiUser {
                HStack(spacing: 12) {
                    RemoteImage(url: user.avatar, targetPointSize: CGSize(width: 88, height: 88), quality: 82)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.nickname.isEmpty ? user.username : user.nickname)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .lineLimit(1)
                        Text("@\(user.username)")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        showsLogoutConfirmation = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.key.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(IbiliTheme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bangumi")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textPrimary)
                        Text("未登录")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    Spacer()
                    Button("登录") { startOAuth() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(12)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IbiliTheme.textSecondary)
            TextField("搜索条目", text: $searchText)
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
                    vm.errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                Task { await search() }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func collectionContent(cardWidth: CGFloat) -> some View {
        if session.bangumiUser == nil {
            emptyState(title: "需要登录", symbol: "person.crop.circle.badge.exclamationmark")
                .padding(.top, 44)
        } else if vm.isLoading && vm.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 44)
        } else if let errorText = vm.errorText, !errorText.isEmpty, vm.items.isEmpty {
            emptyState(title: "加载失败", symbol: "wifi.exclamationmark", message: errorText)
                .padding(.top, 44)
        } else if vm.items.isEmpty {
            emptyState(title: "\(selectedKind.title)为空", symbol: "play.tv")
                .padding(.top, 44)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(vm.items) { item in
                    animeCardButton(
                        subject: item.subject,
                        cardWidth: cardWidth,
                        style: .compact,
                        primaryLine: item.collectionLabel,
                        secondaryLine: progressText(for: item)
                    )
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

    private func animeCardButton(
        subject: AnimeSubjectDTO,
        cardWidth: CGFloat,
        style: PgcPosterCardView.Style,
        primaryLine: String? = nil,
        secondaryLine: String? = nil
    ) -> some View {
        Button {
            router.openAnimeSubject(subject)
        } label: {
            PgcPosterCardView(
                data: PgcPosterCardData(
                    id: subject.id,
                    title: subject.displayTitle,
                    cover: subject.coverURL,
                    score: subject.ratingScore > 0 ? String(format: "%.1f", subject.ratingScore) : "",
                    primaryLine: primaryLine ?? subjectPrimaryLine(subject),
                    secondaryLine: secondaryLine ?? subjectSecondaryLine(subject),
                    description: subject.summary
                ),
                cardWidth: cardWidth,
                imageQuality: 82,
                style: style
            )
        }
        .buttonStyle(.plain)
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

    private func progressText(for item: AnimeCollectionItemDTO) -> String {
        let total = item.subject.totalEpisodes
        guard total > 0 else { return "已看 \(item.epStatus)" }
        return "已看 \(item.epStatus)/\(total)"
    }

    private func subjectPrimaryLine(_ subject: AnimeSubjectDTO) -> String {
        [subject.date, subject.totalEpisodes > 0 ? "\(subject.totalEpisodes) 集" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func subjectSecondaryLine(_ subject: AnimeSubjectDTO) -> String {
        subject.tags.prefix(3).joined(separator: " · ")
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
    private var loadedKind: AnimeCollectionKind?
    private let pageSize: Int64 = 20

    var hasMore: Bool {
        Int64(items.count) < total
    }

    func resetCollection() {
        items = []
        total = 0
        page = 1
        loadedKind = nil
        errorText = nil
    }

    func load(kind: AnimeCollectionKind, session: AppSession, force: Bool = false) async {
        guard let user = session.bangumiUser else {
            resetCollection()
            return
        }
        if isLoading { return }
        if !force, loadedKind == kind, !items.isEmpty { return }
        page = 1
        loadedKind = kind
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
            items = []
            total = 0
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
            loadedKind = kind
            items.append(contentsOf: result.items)
            total = result.total
            errorText = nil
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
            searchResults = []
            errorText = error.localizedDescription
        }
    }
}

struct AnimeSourceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var store: AnimeSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var importText = ""
    @State private var newSubscriptionURL = ""
    @State private var isRefreshingAll = false
    @State private var refreshingURL: String?
    @State private var isImporting = false
    @State private var errorText: String?
    @FocusState private var importEditorFocused: Bool

    var showsDoneButton = false

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await refreshAllSubscriptions() }
                } label: {
                    HStack {
                        Text("刷新全部订阅")
                        Spacer()
                        if isRefreshingAll { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isBusy)

                Button("恢复默认订阅") {
                    Task { await restoreDefaultSubscriptions() }
                }
                .disabled(isBusy)
            } header: {
                Text("订阅")
            }

            Section {
                ForEach(AppSettings.defaultAnimeSourceSubscriptionURLs, id: \.self) { url in
                    subscriptionRow(url: url, isDefault: true)
                }

                let customURLs = settings.customAnimeSourceSubscriptionURLs
                if !customURLs.isEmpty {
                    ForEach(customURLs, id: \.self) { url in
                        subscriptionRow(url: url, isDefault: false)
                    }
                    .onDelete { offsets in
                        settings.removeCustomAnimeSourceSubscriptionURLs(at: offsets)
                        Task { await refreshAllSubscriptions() }
                    }
                }
            } header: {
                Text("订阅地址")
            }

            Section {
                TextField("https://", text: $newSubscriptionURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加并刷新") {
                    Task { await addSubscription() }
                }
                .disabled(isBusy || newSubscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("新增订阅")
            }

            Section {
                TextEditor(text: $importText)
                    .frame(minHeight: 120)
                    .focused($importEditorFocused)
                Button("导入 JSON") {
                    Task { await importJSON() }
                }
                .disabled(isBusy || importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                                Text(sourceTypeLabel(source.factoryID))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("数据源")
            } footer: {
                if !store.sources.isEmpty {
                    Text("已启用 \(store.sources.filter(\.enabled).count) / \(store.sources.count)")
                }
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("数据源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { importEditorFocused = false }
            }
        }
    }

    private var isBusy: Bool {
        isRefreshingAll || refreshingURL != nil || isImporting
    }

    @ViewBuilder
    private func subscriptionRow(url: String, isDefault: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isDefault ? "默认订阅" : "自定义订阅")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                Task { await refreshSubscription(url) }
            } label: {
                if refreshingURL == url {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
        }
    }

    private func addSubscription() async {
        let added = settings.addAnimeSourceSubscriptionURL(newSubscriptionURL)
        newSubscriptionURL = ""
        guard added else { return }
        await refreshAllSubscriptions()
    }

    private func refreshSubscription(_ url: String) async {
        refreshingURL = url
        defer { refreshingURL = nil }
        do {
            try await store.updateSubscription(url: url)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshAllSubscriptions() async {
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        do {
            try await store.refreshConfiguredSubscriptions()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func restoreDefaultSubscriptions() async {
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        do {
            try await store.refreshDefaultSubscriptions()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importJSON() async {
        isImporting = true
        defer { isImporting = false }
        do {
            try await store.importJSON(importText)
            importText = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func sourceTypeLabel(_ factoryID: String) -> String {
        switch factoryID {
        case "rss": return "RSS"
        case "web-selector": return "Web Selector"
        default: return factoryID
        }
    }
}
