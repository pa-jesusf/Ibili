import SwiftUI

struct MessageToolbarButton: View {
    let unreadCount: Int64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "envelope")
                .font(.body.weight(.semibold))
                .foregroundStyle(IbiliTheme.accent)
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        MessageUnreadBadge(count: unreadCount, compact: true)
                            .offset(x: 9, y: -7)
                    }
                }
        }
        .tint(IbiliTheme.accent)
        .accessibilityLabel(unreadCount > 0 ? "消息，\(unreadCount) 条未读" : "消息")
    }
}

struct MessageCenterView: View {
    @Environment(\.rootContentNavigation) private var rootNavigation
    @StateObject private var vm = MessageCenterViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(MessageFeedKind.allCases) { kind in
                        Button {
                            vm.clearUnread(kind)
                            rootNavigation.openMessageFeed(kind)
                        } label: {
                            MessageKindCard(
                                kind: kind,
                                unreadCount: vm.summary.count(for: kind)
                            )
                        }
                    }
                }
                .buttonStyle(.plain)

                IbiliSectionHeader(title: "私信", systemImage: "message", iconColor: IbiliTheme.accent)

                if vm.isLoadingSessions && vm.sessions.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(IbiliTheme.accent)
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else if vm.sessions.isEmpty {
                    emptyState(
                        title: vm.sessionError == nil ? "暂无私信" : "私信加载失败",
                        symbol: vm.sessionError == nil ? "tray" : "wifi.exclamationmark",
                        message: vm.sessionError
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(vm.sessions) { session in
                            Button {
                                rootNavigation.openUserSpace(mid: session.talkerID)
                            } label: {
                                MessageSessionRow(session: session)
                            }
                            .buttonStyle(.plain)

                            if session.id != vm.sessions.last?.id {
                                Divider().padding(.leading, 74)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(IbiliTheme.surface)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await vm.loadInitial()
        }
        .refreshable {
            await vm.reload()
        }
        .tint(IbiliTheme.accent)
    }
}

struct MessageFeedListView: View {
    let kind: MessageFeedKind
    @Environment(\.rootContentNavigation) private var rootNavigation
    @Environment(\.openURL) private var openURL
    @StateObject private var vm: MessageFeedListViewModel

    init(kind: MessageFeedKind) {
        self.kind = kind
        _vm = StateObject(wrappedValue: MessageFeedListViewModel(kind: kind))
    }

    var body: some View {
        ZStack {
            VirtualizedCollectionSurface(
                items: vm.items,
                layout: .list(
                    horizontalInset: 16,
                    topInset: 16,
                    bottomInset: 16,
                    spacing: 12,
                    estimatedHeight: 150
                ),
                footer: messageFooter,
                showsRefresh: true,
                isRefreshing: vm.isLoading,
                prefetchThreshold: 3,
                onRefresh: {
                    Task { await vm.reload() }
                },
                onLoadMore: {
                    Task { await vm.loadMore() }
                }
            ) { item, _ in
                AnyView(
                    Button {
                        openMessageItem(item)
                    } label: {
                        MessageItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .modifier(ProMotionScrollHint())

            if vm.items.isEmpty {
                messageEmptyState
                    .padding(.horizontal, 24)
            }
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await vm.loadInitial()
        }
        .tint(IbiliTheme.accent)
    }

    @ViewBuilder
    private var messageEmptyState: some View {
        if vm.isLoading {
            ProgressView().tint(IbiliTheme.accent)
        } else if let error = vm.error {
            VStack(spacing: 14) {
                emptyState(
                    title: "\(kind.title)加载失败",
                    symbol: "wifi.exclamationmark",
                    message: error
                )
                Button("重试") {
                    Task { await vm.reload() }
                }
                .buttonStyle(.borderedProminent)
                .tint(IbiliTheme.accent)
            }
        } else {
            emptyState(title: "暂无\(kind.title)", symbol: kind.symbol)
        }
    }

    private var messageFooter: (() -> AnyView)? {
        guard !vm.items.isEmpty else { return nil }
        if vm.isLoadingMore {
            return {
                AnyView(
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                )
            }
        }
        if !vm.hasMore {
            return {
                AnyView(
                    Text("已经到底了")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                )
            }
        }
        return nil
    }

    private func openMessageItem(_ item: MessageItemDTO) {
        let mapped = MessageLinkMapper.internalURLString(from: item.nativeUri)
        if let url = URL(string: mapped), url.scheme?.lowercased() == "ibili" {
            openURL(url)
        } else if item.userMid > 0 {
            rootNavigation.openUserSpace(mid: item.userMid)
        }
    }
}

@MainActor
final class MessageUnreadViewModel: ObservableObject {
    @Published private(set) var summary = MessageUnreadSummaryDTO.empty
    private var isLoading = false

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            summary = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.messageUnreadSummary()
            }.value
        } catch {
            AppLog.warning("message", "消息未读数加载失败", metadata: [
                "error": error.localizedDescription,
            ])
            summary = .empty
        }
    }
}

@MainActor
private final class MessageCenterViewModel: ObservableObject {
    @Published var summary = MessageUnreadSummaryDTO.empty
    @Published var sessions: [MessageSessionDTO] = []
    @Published var isLoadingSessions = false
    @Published var sessionError: String?

    private var hasLoaded = false

    func loadInitial() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        await reloadSummary()
        await reloadSessions()
    }

    func clearUnread(_ kind: MessageFeedKind) {
        summary = summary.clearing(kind)
    }

    private func reloadSummary() async {
        do {
            summary = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.messageUnreadSummary()
            }.value
        } catch {
            AppLog.warning("message", "消息未读数加载失败", metadata: [
                "error": error.localizedDescription,
            ])
            summary = .empty
        }
    }

    private func reloadSessions() async {
        guard !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.messageSessions()
            }.value
            sessions = page.items
            sessionError = nil
        } catch {
            AppLog.warning("message", "私信会话加载失败", metadata: [
                "error": error.localizedDescription,
            ])
            sessionError = error.localizedDescription
            sessions = []
        }
    }
}

@MainActor
private final class MessageFeedListViewModel: ObservableObject {
    let kind: MessageFeedKind
    @Published var items: [MessageItemDTO] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var error: String?
    @Published var hasMore = false

    private var hasLoaded = false
    private var nextCursorID: Int64 = 0
    private var nextCursorTime: Int64 = 0

    init(kind: MessageFeedKind) {
        self.kind = kind
    }

    func loadInitial() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        await fetch(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        if reset {
            guard !isLoading else { return }
            isLoading = true
            nextCursorID = 0
            nextCursorTime = 0
        } else {
            guard !isLoadingMore else { return }
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }

        do {
            let cursorID = reset ? 0 : nextCursorID
            let cursorTime = reset ? 0 : nextCursorTime
            let page = try await Task.detached(priority: .userInitiated) { [kind] in
                try CoreClient.shared.messageFeed(
                    kind: kind.rawValue,
                    cursorID: cursorID,
                    cursorTime: cursorTime
                )
            }.value
            if reset {
                items = page.items
            } else {
                let existing = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            nextCursorID = page.nextCursorID
            nextCursorTime = page.nextCursorTime
            hasMore = page.hasMore
            error = nil
        } catch {
            AppLog.warning("message", "消息列表加载失败", metadata: [
                "kind": kind.rawValue,
                "reset": String(reset),
                "error": error.localizedDescription,
            ])
            self.error = error.localizedDescription
        }
    }
}

private struct MessageKindCard: View {
    let kind: MessageFeedKind
    let unreadCount: Int64

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(IbiliTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(IbiliTheme.accent.opacity(0.12)))
                if unreadCount > 0 {
                    MessageUnreadBadge(count: unreadCount, compact: true)
                        .offset(x: 8, y: -5)
                }
            }

            Text(kind.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IbiliTheme.textSecondary.opacity(0.6))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(IbiliTheme.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MessageSessionRow: View {
    let session: MessageSessionDTO

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: session.avatar,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 48, height: 48),
                        quality: 75)
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(1)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(IbiliTheme.accent)
                    }
                    if session.isMuted {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(BiliFormat.relativeDate(session.timestamp))
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }

                HStack(spacing: 8) {
                    Text(session.lastMessage.isEmpty ? "暂无消息" : session.lastMessage)
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if session.unread > 0 {
                        MessageUnreadBadge(count: session.unread)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct MessageItemRow: View {
    let item: MessageItemDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headerText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timeText)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }

                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(2)
                }

                if !item.content.isEmpty {
                    Text(item.content)
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(3)
                }

                if !item.secondaryContent.isEmpty {
                    Text(item.secondaryContent)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(2)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(IbiliTheme.background)
                        )
                }

                if !item.image.isEmpty {
                    RemoteImage(url: item.image,
                                contentMode: .fill,
                                targetPointSize: CGSize(width: 128, height: 72),
                                quality: 70)
                        .frame(width: 128, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    @ViewBuilder
    private var avatar: some View {
        if item.userMid > 0 {
            RemoteImage(url: item.userAvatar,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 44, height: 44),
                        quality: 75)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
        } else {
            Image(systemName: "bell.badge")
                .font(.title3)
                .foregroundStyle(IbiliTheme.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(IbiliTheme.accent.opacity(0.12)))
        }
    }

    private var headerText: String {
        if item.userName.isEmpty {
            return item.action.isEmpty ? "系统通知" : item.action
        }
        if item.action.isEmpty {
            return item.userName
        }
        return "\(item.userName) \(item.action)"
    }

    private var timeText: String {
        if !item.timeText.isEmpty {
            return item.timeText
        }
        return BiliFormat.relativeDate(item.timestamp)
    }
}

private struct MessageUnreadBadge: View {
    let count: Int64
    var compact = false

    var body: some View {
        Text(displayText)
            .font(compact ? .caption2.weight(.bold) : .caption2.weight(.semibold))
            .foregroundStyle(.white)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, compact ? 5 : 6)
            .frame(minWidth: compact ? 18 : 20, minHeight: compact ? 18 : 20)
            .background(Capsule().fill(IbiliTheme.accent))
    }

    private var displayText: String {
        count > 99 ? "99+" : String(max(1, count))
    }
}

private enum MessageLinkMapper {
    static func internalURLString(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "about:blank" }
        if let mapped = mapNativeURL(trimmed) {
            return mapped
        }
        return LinkRouter.mapToInternalURL(trimmed)
    }

    private static func mapNativeURL(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "bilibili" else {
            return nil
        }
        let host = (components.host ?? "").lowercased()
        let full = raw.removingPercentEncoding ?? raw
        let query = components.queryItems ?? []
        let queryValue: (String) -> String? = { name in
            query.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch host {
        case "video":
            if let bvid = queryValue("bvid") ?? LinkRouter.extractBV(from: full) {
                return "ibili://bv/\(bvid)"
            }
            if let aid = firstNumber(in: full) {
                return "ibili://av/\(aid)"
            }
        case "space", "user", "author":
            if let mid = queryValue("mid") ?? queryValue("vmid") ?? firstNumber(in: full) {
                return "ibili://space/\(mid)"
            }
        case "live":
            if let roomID = firstNumber(in: full) {
                return "ibili://live/\(roomID)"
            }
        case "article", "read":
            if let cvid = LinkRouter.extractCV(from: full) ?? firstNumber(in: full) {
                return "ibili://article/read/\(cvid)"
            }
        case "opus", "dynamic":
            if let opusID = firstNumber(in: full) {
                return "ibili://article/opus/\(opusID)"
            }
        case "pgc", "bangumi":
            if full.contains("ep"), let epID = firstNumber(in: full) {
                return "ibili://pgc/ep/\(epID)"
            }
            if let seasonID = firstNumber(in: full) {
                return "ibili://pgc/ss/\(seasonID)"
            }
        case "search":
            if let keyword = queryValue("keyword"), !keyword.isEmpty {
                return LinkRouter.searchURL(keyword: keyword)
            }
        default:
            break
        }
        return nil
    }

    private static func firstNumber(in raw: String) -> String? {
        guard let range = raw.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return String(raw[range])
    }
}

private extension MessageUnreadSummaryDTO {
    func count(for kind: MessageFeedKind) -> Int64 {
        switch kind {
        case .reply:
            return reply
        case .at:
            return at
        case .like:
            return like
        case .system:
            return sysMsg
        }
    }

    func clearing(_ kind: MessageFeedKind) -> MessageUnreadSummaryDTO {
        let clearedCount = count(for: kind)
        let nextTotal = max(0, total - clearedCount)
        switch kind {
        case .reply:
            return MessageUnreadSummaryDTO(reply: 0, at: at, like: like, sysMsg: sysMsg, whisper: whisper, total: nextTotal)
        case .at:
            return MessageUnreadSummaryDTO(reply: reply, at: 0, like: like, sysMsg: sysMsg, whisper: whisper, total: nextTotal)
        case .like:
            return MessageUnreadSummaryDTO(reply: reply, at: at, like: 0, sysMsg: sysMsg, whisper: whisper, total: nextTotal)
        case .system:
            return MessageUnreadSummaryDTO(reply: reply, at: at, like: like, sysMsg: 0, whisper: whisper, total: nextTotal)
        }
    }
}
