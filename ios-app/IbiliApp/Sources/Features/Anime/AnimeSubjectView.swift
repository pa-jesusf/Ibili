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
                    heroHeader(subject)
                    quickActionSection(subject)
                    episodeSection(subject)
                    if !subject.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        summarySection(subject)
                    }
                    if !subject.tags.isEmpty {
                        tagSection(subject)
                    }
                    if !subject.infoItems.isEmpty {
                        infoSection(subject)
                    }
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

    private func heroHeader(_ subject: AnimeSubjectDTO) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: subject.coverURL, targetPointSize: CGSize(width: 760, height: 430), quality: 70)
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 248)
                .clipped()
                .blur(radius: 18)
                .scaleEffect(1.08)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.15), .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            HStack(alignment: .bottom, spacing: 14) {
                RemoteImage(url: subject.coverURL, targetPointSize: CGSize(width: 236, height: 332), quality: 86)
                    .frame(width: 118, height: 166)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 16, x: 0, y: 10)

                VStack(alignment: .leading, spacing: 9) {
                    Text(subject.displayTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    if subject.displayTitle != subject.name, !subject.name.isEmpty {
                        Text(subject.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(2)
                    }

                    HStack(spacing: 7) {
                        AnimeHeroBadge(text: subject.collectionType > 0 ? subject.collectionLabel : "未收藏", highlighted: subject.collectionType > 0)
                        if !subject.date.isEmpty {
                            AnimeHeroBadge(text: subject.date, highlighted: false)
                        }
                    }
                }
                .padding(.bottom, 2)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func quickActionSection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AnimeMetricPill(title: subject.ratingScore > 0 ? String(format: "%.1f", subject.ratingScore) : "-", subtitle: "\(subject.ratingTotal) 人评分", emphasized: true)
                if subject.rank > 0 {
                    AnimeMetricPill(title: "#\(subject.rank)", subtitle: "Rank", emphasized: false)
                }
                AnimeMetricPill(title: subject.totalEpisodes > 0 ? "\(subject.totalEpisodes)" : "\(subject.episodes.count)", subtitle: "集数", emphasized: false)
            }

            HStack(spacing: 10) {
                if let episode = preferredEpisode(subject) {
                    Button {
                        openEpisode(episode, reason: "primary-action")
                    } label: {
                        Label(primaryEpisodeTitle(subject, episode), systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(IbiliTheme.accent)
                }

                Button {
                    guard subject.collectionType == 0 else { return }
                    Task { await updateCollection(3) }
                } label: {
                    Label(subject.collectionType > 0 ? subject.collectionLabel : "加入收藏", systemImage: subject.collectionType > 0 ? "checkmark.circle.fill" : "plus.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .tint(IbiliTheme.accent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func summarySection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("简介")
                .font(.headline)
            VideoDescriptionView(desc: subject.summary, descV2: [])
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func tagSection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标签")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(subject.tags.prefix(16), id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private func infoSection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("资料")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(subject.infoItems.prefix(12)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(width: 68, alignment: .leading)
                        Text(item.value)
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textPrimary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    if item.id != subject.infoItems.prefix(12).last?.id {
                        Divider().opacity(0.45)
                    }
                }
            }
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
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach([(3, "在看"), (1, "想看"), (2, "看过"), (4, "搁置"), (5, "抛弃")], id: \.0) { value, label in
                    let isSelected = subject.collectionType == Int64(value)
                    Button(label) {
                        Task { await updateCollection(value) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textSecondary)
                    .frame(width: 78)
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
            let previous = subject ?? initialSubject
            let merged = mergeCollectionState(detail, fallback: previous)
            AppLog.info("anime", "追番详情加载完成", metadata: [
                "subjectID": String(id),
                "detailCollectionType": String(detail.collectionType),
                "fallbackCollectionType": String(previous?.collectionType ?? 0),
                "mergedCollectionType": String(merged.collectionType),
                "detailEpStatus": String(detail.epStatus),
                "fallbackEpStatus": String(previous?.epStatus ?? 0),
                "mergedEpStatus": String(merged.epStatus),
                "episodeCount": String(merged.episodes.count),
            ])
            subject = merged
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            AppLog.error("anime", "追番详情加载失败", error: error, metadata: [
                "subjectID": String(subjectID),
            ])
        }
    }

    private func updateCollection(_ collectionType: Int) async {
        guard session.bangumiSession != nil else {
            AppLog.warning("anime", "追番收藏更新跳过：未登录 Bangumi", metadata: [
                "subjectID": String(subjectID),
                "collectionType": String(collectionType),
            ])
            return
        }
        guard collectionType > 0 else {
            AppLog.warning("anime", "追番收藏更新跳过：无效收藏类型", metadata: [
                "subjectID": String(subjectID),
                "collectionType": String(collectionType),
            ])
            return
        }
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
            AppLog.info("anime", "追番收藏更新成功", metadata: [
                "subjectID": String(id),
                "collectionType": String(collectionType),
            ])
            await load()
        } catch {
            errorText = error.localizedDescription
            AppLog.error("anime", "追番收藏更新失败", error: error, metadata: [
                "subjectID": String(subjectID),
                "collectionType": String(collectionType),
            ])
        }
    }

    private func mergeCollectionState(
        _ detail: AnimeSubjectDTO,
        fallback: AnimeSubjectDTO?
    ) -> AnimeSubjectDTO {
        guard let fallback, fallback.id == detail.id else { return detail }
        let collectionType = detail.collectionType > 0 ? detail.collectionType : fallback.collectionType
        let collectionLabel = detail.collectionType > 0
            ? detail.collectionLabel
            : (fallback.collectionType > 0 ? fallback.collectionLabel : detail.collectionLabel)
        let epStatus = detail.epStatus > 0 ? detail.epStatus : fallback.epStatus
        let episodes = mergeEpisodeCollectionState(detail.episodes, fallback: fallback.episodes)
        return AnimeSubjectDTO(
            id: detail.id,
            name: detail.name,
            nameCn: detail.nameCn,
            summary: detail.summary,
            date: detail.date,
            image: detail.image,
            ratingScore: detail.ratingScore,
            ratingTotal: detail.ratingTotal,
            rank: detail.rank,
            collectionType: collectionType,
            collectionLabel: collectionLabel,
            epStatus: epStatus,
            totalEpisodes: detail.totalEpisodes,
            tags: detail.tags,
            aliases: detail.aliases,
            infoItems: detail.infoItems,
            episodes: episodes
        )
    }

    private func mergeEpisodeCollectionState(
        _ episodes: [AnimeEpisodeDTO],
        fallback: [AnimeEpisodeDTO]
    ) -> [AnimeEpisodeDTO] {
        let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0.collectionType) })
        let fallbackBySort = Dictionary(uniqueKeysWithValues: fallback.map { (episodeCollectionKey($0.sort), $0.collectionType) })
        return episodes.map { episode in
            guard episode.collectionType == 0 else { return episode }
            let mergedType = fallbackByID[episode.id] ?? fallbackBySort[episodeCollectionKey(episode.sort)] ?? 0
            guard mergedType > 0 else { return episode }
            return AnimeEpisodeDTO(
                id: episode.id,
                subjectID: episode.subjectID,
                sort: episode.sort,
                ep: episode.ep,
                name: episode.name,
                nameCn: episode.nameCn,
                duration: episode.duration,
                airdate: episode.airdate,
                desc: episode.desc,
                collectionType: mergedType
            )
        }
    }

    private func episodeCollectionKey(_ sort: Double) -> String {
        String(format: "%.3f", sort)
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

    private func preferredEpisode(_ subject: AnimeSubjectDTO) -> AnimeEpisodeDTO? {
        subject.episodes.first { $0.collectionType != 2 } ?? subject.episodes.first
    }

    private func primaryEpisodeTitle(_ subject: AnimeSubjectDTO, _ episode: AnimeEpisodeDTO) -> String {
        if episode.collectionType == 2 {
            return "重看 \(episode.displayTitle)"
        }
        if subject.epStatus > 0 {
            return "继续 \(episode.displayTitle)"
        }
        return "播放 \(episode.displayTitle)"
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

private struct AnimeHeroBadge: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(highlighted ? IbiliTheme.accent : .white.opacity(0.86))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(highlighted ? IbiliTheme.accent.opacity(0.55) : .white.opacity(0.18), lineWidth: 0.7)
            )
    }
}

private struct AnimeMetricPill: View {
    let title: String
    let subtitle: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(emphasized ? IbiliTheme.accent : IbiliTheme.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(IbiliTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(emphasized ? IbiliTheme.accent.opacity(0.10) : Color(.tertiarySystemFill))
        )
    }
}
