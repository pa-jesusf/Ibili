import SwiftUI

struct AnimeSubjectView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @State private var subject: AnimeSubjectDTO?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selectedEpisode: AnimeEpisodeDTO?
    @State private var candidates: [AnimeMediaCandidateDTO] = []
    @State private var isFetchingMedia = false
    @State private var showsPicker = false

    let subjectID: Int64
    let initialSubject: AnimeSubjectDTO?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let subject {
                    header(subject)
                    if !subject.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VideoDescriptionView(desc: subject.summary, descV2: [])
                    }
                    episodeSection(subject)
                    statusSection(subject)
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    emptyState(title: "条目加载失败", symbol: "play.tv", message: errorText ?? "请稍后重试")
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(IbiliTheme.background)
        .navigationTitle(subject?.displayTitle ?? initialSubject?.displayTitle ?? "追番")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subjectID) {
            subject = initialSubject
            await load()
        }
        .sheet(isPresented: $showsPicker) {
            if let subject, let episode = selectedEpisode {
                NavigationStack {
                    AnimeSourcePickerSheet(
                        subject: subject,
                        episode: episode,
                        candidates: candidates,
                        isLoading: isFetchingMedia,
                        onRefresh: {
                            Task { await fetchMedia(for: episode, showSheet: true) }
                        },
                        onPick: { candidate in
                            resolve(candidate: candidate, subject: subject, episode: episode)
                        }
                    )
                }
            }
        }
        .tint(IbiliTheme.accent)
    }

    private func header(_ subject: AnimeSubjectDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: subject.coverURL, targetPointSize: CGSize(width: 168, height: 224), quality: 82)
                .frame(width: 84, height: 112)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Text(subject.displayTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if subject.displayTitle != subject.name, !subject.name.isEmpty {
                    Text(subject.name)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(subject.ratingScore > 0 ? String(format: "评分 %.1f", subject.ratingScore) : "评分 -")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                    if subject.rank > 0 {
                        Text("Rank \(subject.rank)")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                }
                let meta = [subject.date, subject.totalEpisodes > 0 ? "\(subject.totalEpisodes) 集" : ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                if subject.collectionType > 0 {
                    Text(subject.collectionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func episodeSection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选集")
                        .font(.headline)
                    Text("点击后从规则源查找可播放资源")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer()
                if isFetchingMedia {
                    ProgressView().controlSize(.small)
                }
            }

            if subject.episodes.isEmpty {
                Text("暂无分集数据")
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(subject.episodes.enumerated()), id: \.element.id) { index, episode in
                            AnimeEpisodeChip(
                                episode: episode,
                                index: index + 1,
                                isWatched: episode.collectionType == 2
                            ) {
                                Task { await fetchMedia(for: episode, showSheet: true) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .background(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: true))
                .overlay(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: false))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func statusSection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("收藏状态")
                .font(.headline)
            HStack {
                ForEach([(3, "在看"), (1, "想看"), (2, "看过"), (4, "搁置"), (5, "抛弃")], id: \.0) { value, label in
                    Button(label) {
                        Task { await updateCollection(value) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(subject.collectionType == Int64(value) ? IbiliTheme.accent : .secondary)
                }
            }
            .buttonBorderShape(.capsule)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let accessToken = session.bangumiAccessToken
            let id = subjectID
            let detail = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeSubjectDetail(
                    accessToken: accessToken,
                    subjectID: id
                )
            }.value
            subject = detail
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func updateCollection(_ collectionType: Int) async {
        guard session.bangumiSession != nil else { return }
        do {
            let accessToken = session.bangumiAccessToken
            let id = subjectID
            let type = Int64(collectionType)
            try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeCollectionUpdate(
                    accessToken: accessToken,
                    subjectID: id,
                    collectionType: type
                )
            }.value
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func fetchMedia(for episode: AnimeEpisodeDTO, showSheet: Bool) async {
        guard let subject else { return }
        selectedEpisode = episode
        if showSheet { showsPicker = true }
        isFetchingMedia = true
        defer { isFetchingMedia = false }
        do {
            let sourcesJSON = try sourceStore.enabledSourcesJSON()
            let names = [subject.nameCn, subject.name] + subject.aliases
            let result = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.animeMediaFetch(
                    sourcesJSON: sourcesJSON,
                    subjectNames: names,
                    episodeSort: episode.sort,
                    episodeName: episode.displayTitle
                )
            }.value
            candidates = result.candidates
            errorText = nil
        } catch {
            candidates = []
            errorText = error.localizedDescription
        }
    }

    private func resolve(candidate: AnimeMediaCandidateDTO, subject: AnimeSubjectDTO, episode: AnimeEpisodeDTO) {
        Task {
            do {
                let play = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.animeMediaResolve(
                        candidate: candidate,
                        title: "\(subject.displayTitle) · \(episode.displayTitle)",
                        cover: subject.coverURL
                    )
                }.value
                showsPicker = false
                router.openAnimePlayer(play: play, subject: subject, episode: episode)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

private struct AnimeEpisodeChip: View {
    let episode: AnimeEpisodeDTO
    let index: Int
    let isWatched: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index))
                        .font(.caption2.weight(.bold).monospacedDigit())
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                    }
                }
                .foregroundStyle(isWatched ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(episode.displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isWatched ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 124, height: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isWatched ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isWatched ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AnimeSourcePickerSheet: View {
    let subject: AnimeSubjectDTO
    let episode: AnimeEpisodeDTO
    let candidates: [AnimeMediaCandidateDTO]
    let isLoading: Bool
    let onRefresh: () -> Void
    let onPick: (AnimeMediaCandidateDTO) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.displayTitle)
                            .font(.headline)
                        Text(subject.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Section {
                if candidates.isEmpty && !isLoading {
                    Text("没有找到可用资源。请检查规则源，或等待源站更新。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            guard candidate.isSupported else { return }
                            onPick(candidate)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: candidate.isSupported ? "play.circle.fill" : "exclamationmark.triangle")
                                    .foregroundStyle(candidate.isSupported ? IbiliTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(IbiliTheme.textPrimary)
                                        .lineLimit(2)
                                    Text([candidate.sourceName, candidate.qualityLabel, candidate.kind.uppercased()]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(IbiliTheme.textSecondary)
                                    if !candidate.isSupported {
                                        Text(candidate.unsupportedReason)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        .disabled(!candidate.isSupported)
                    }
                }
            }
        }
        .navigationTitle("选择资源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }
}
