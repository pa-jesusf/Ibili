import SwiftUI

struct AnimeSubjectView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @State private var subject: AnimeSubjectDTO?
    @State private var isLoading = false
    @State private var errorText: String?

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
            await sourceStore.ensureDefaultSubscriptionsLoaded()
            await load()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, needsMetadataReload else { return }
            Task { await load() }
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
                Text("选集")
                    .font(.headline)
                Spacer()
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
                                stateLabel: episodeStateLabel(episode.collectionType)
                            ) {
                                openEpisode(episode, reason: "tap")
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
            HStack {
                Text("收藏状态")
                    .font(.headline)
                Spacer()
            }
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 72), spacing: 8)
            ], alignment: .leading, spacing: 8) {
                ForEach([(3, "在看"), (1, "想看"), (2, "看过"), (4, "搁置"), (5, "抛弃")], id: \.0) { value, label in
                    let isSelected = subject.collectionType == Int64(value)
                    Button(label) {
                        Task { await updateCollection(value) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func load() async {
        if subject == nil {
            subject = initialSubject
        }
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

    private func openEpisode(_ episode: AnimeEpisodeDTO, reason: String) {
        guard let subject else {
            AppLog.warning("anime", "追番集数打开跳过：缺少条目元数据", metadata: [
                "subjectID": String(subjectID),
                "episodeID": String(episode.id),
                "reason": reason,
            ])
            return
        }
        AppLog.info("anime", "追番集数已选择", metadata: [
            "subjectID": String(subject.id),
            "episodeID": String(episode.id),
            "episodeSort": String(format: "%.2f", episode.sort),
            "reason": reason,
        ])
        router.openAnimeEpisode(subject: subject, episode: episode)
    }

    private var needsMetadataReload: Bool {
        guard !isLoading else { return false }
        guard let subject else { return true }
        return subject.episodes.isEmpty
    }

    private func episodeStateLabel(_ value: Int64) -> String {
        switch value {
        case 1: return "想看"
        case 2: return "看过"
        case 3: return "在看"
        case 4: return "搁置"
        case 5: return "抛弃"
        default: return ""
        }
    }
}

private struct AnimeEpisodeChip: View {
    let episode: AnimeEpisodeDTO
    let index: Int
    let stateLabel: String
    let onTap: () -> Void

    private var hasState: Bool {
        !stateLabel.isEmpty
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index))
                        .font(.caption2.weight(.bold).monospacedDigit())
                    if hasState {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                    }
                }
                .foregroundStyle(hasState ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(episode.displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(hasState ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if hasState {
                    Text(stateLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 124, height: 80, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hasState ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hasState ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
