import SwiftUI

struct MessageConversationView: View {
    let session: MessageSessionDTO

    @Environment(\.rootContentNavigation) private var rootNavigation
    @StateObject private var viewModel: MessageConversationViewModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(session: MessageSessionDTO) {
        self.session = session
        _viewModel = StateObject(
            wrappedValue: MessageConversationViewModel(talkerID: session.talkerID)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    historyHeader

                    ForEach(viewModel.items) { item in
                        MessageBubbleRow(item: item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.scrollTarget) { target in
                guard let target else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                conversationIdentityButton
            }
        }
        .task {
            await viewModel.loadInitial()
        }
        .refreshable {
            await viewModel.reload()
        }
        .tint(IbiliTheme.accent)
    }

    private var conversationIdentityButton: some View {
        Button {
            rootNavigation.openUserSpace(mid: session.talkerID)
        } label: {
            HStack(spacing: 7) {
                RemoteImage(
                    url: session.avatar,
                    contentMode: .fill,
                    targetPointSize: CGSize(width: 28, height: 28),
                    quality: 75
                )
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                Text(session.name)
                    .font(.headline)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("查看\(session.name)的个人空间")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = viewModel.sendError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            GlassSurface(cornerRadius: 22) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("发消息", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .onSubmit(sendDraft)
                        .padding(.leading, 4)
                        .padding(.vertical, 7)

                    Button(action: sendDraft) {
                        Group {
                            if viewModel.isSending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.callout.weight(.semibold))
                            }
                        }
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(Circle().fill(IbiliTheme.accent))
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedDraft.isEmpty || viewModel.isSending)
                    .opacity(trimmedDraft.isEmpty ? 0.45 : 1)
                    .accessibilityLabel("发送")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendDraft() {
        let message = trimmedDraft
        guard !message.isEmpty, !viewModel.isSending else { return }
        Task {
            if await viewModel.send(message) {
                draft = ""
                composerFocused = false
            }
        }
    }

    @ViewBuilder
    private var historyHeader: some View {
        if viewModel.isLoadingOlder {
            ProgressView()
                .tint(IbiliTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if viewModel.hasMore {
            Button("加载更早的消息") {
                Task { await viewModel.loadOlder() }
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            .padding(.vertical, 4)
        } else if viewModel.items.isEmpty {
            if viewModel.isLoading {
                ProgressView()
                    .tint(IbiliTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                emptyState(
                    title: viewModel.error == nil ? "暂无消息" : "对话加载失败",
                    symbol: viewModel.error == nil ? "message" : "wifi.exclamationmark",
                    message: viewModel.error
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }
}

@MainActor
private final class MessageConversationViewModel: ObservableObject {
    let talkerID: Int64

    @Published private(set) var items: [MessageChatItemDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    @Published private(set) var scrollTarget: String?
    @Published private(set) var isSending = false
    @Published private(set) var sendError: String?

    private var nextSequence: Int64 = 0
    private var hasLoaded = false

    init(talkerID: Int64) {
        self.talkerID = talkerID
    }

    func loadInitial() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await fetch(reset: true)
    }

    func reload() async {
        await fetch(reset: true)
    }

    func loadOlder() async {
        guard hasMore, !isLoading, !isLoadingOlder else { return }
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        if reset {
            guard !isLoading else { return }
            isLoading = true
        } else {
            guard !isLoadingOlder else { return }
            isLoadingOlder = true
        }
        defer {
            isLoading = false
            isLoadingOlder = false
        }

        do {
            let endSequence = reset ? 0 : nextSequence
            let page = try await Task.detached(priority: .userInitiated) { [talkerID] in
                try CoreClient.shared.messageConversation(
                    talkerID: talkerID,
                    endSequence: endSequence
                )
            }.value
            let sorted = page.items.sorted {
                if $0.sequence == $1.sequence { return $0.timestamp < $1.timestamp }
                return $0.sequence < $1.sequence
            }
            if reset {
                items = deduplicated(sorted)
                scrollTarget = items.last?.id
            } else {
                items = deduplicated(sorted + items)
            }
            nextSequence = page.nextSequence
            hasMore = page.hasMore && page.nextSequence > 0
            error = nil

            if reset, page.ackSequence > 0 {
                Task.detached(priority: .utility) { [talkerID] in
                    try? CoreClient.shared.acknowledgeMessageConversation(
                        talkerID: talkerID,
                        sequence: page.ackSequence
                    )
                }
            }
        } catch {
            self.error = error.localizedDescription
            AppLog.error("message", "私信对话加载失败", error: error, metadata: [
                "talkerID": String(talkerID),
            ])
        }
    }

    func send(_ message: String) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            let sent = try await Task.detached(priority: .userInitiated) { [talkerID] in
                try CoreClient.shared.sendMessageText(talkerID: talkerID, message: message)
            }.value
            withAnimation(.easeOut(duration: 0.2)) {
                items = deduplicated(items + [sent])
            }
            scrollTarget = sent.id
            return true
        } catch {
            sendError = error.localizedDescription
            AppLog.error("message", "私信发送失败", error: error, metadata: [
                "talkerID": String(talkerID),
            ])
            return false
        }
    }

    private func deduplicated(_ incoming: [MessageChatItemDTO]) -> [MessageChatItemDTO] {
        var seen = Set<String>()
        return incoming.filter { seen.insert($0.id).inserted }
    }
}

private struct MessageBubbleRow: View {
    let item: MessageChatItemDTO

    var body: some View {
        if item.kind == "notice" {
            Text(item.text)
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: item.isSelf ? .trailing : .leading, spacing: 4) {
                bubble
                Text(BiliFormat.relativeDate(item.timestamp))
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: item.isSelf ? .trailing : .leading)
        }
    }

    private var bubble: some View {
        GlassSurface(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if !item.image.isEmpty {
                    RemoteImage(
                        url: item.image,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 240, height: 180),
                        quality: 80
                    )
                    .frame(width: 220, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.body)
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(item.isSelf ? IbiliTheme.accent.opacity(0.38) : Color.clear, lineWidth: 1)
            )
        }
        .frame(maxWidth: 300, alignment: item.isSelf ? .trailing : .leading)
    }
}
