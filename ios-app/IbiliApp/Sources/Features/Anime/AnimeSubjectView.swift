import SwiftUI

struct AnimeSubjectView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sourceStore = AnimeSourceStore.shared
    @State private var subject: AnimeSubjectDTO?
    @State private var relations = AnimeSubjectRelationsDTO(characters: [], staff: [])
    @State private var reviews: [AnimeSubjectReviewDTO] = []
    @State private var reviewsTotal: Int64 = 0
    @State private var isLoading = false
    @State private var isLoadingRelations = false
    @State private var isLoadingReviews = false
    @State private var didLoadReviews = false
    @State private var errorText: String?
    @State private var reviewErrorText: String?
    @State private var selectedTab: AnimeSubjectTab = .details
    @State private var peopleSheet: AnimePeopleSheet?

    let subjectID: Int64
    let initialSubject: AnimeSubjectDTO?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let subject {
                    subjectHero(subject)
                    actionPanel(subject)
                    episodeSection(subject)
                    IbiliSegmentedTabs(
                        tabs: AnimeSubjectTab.allCases,
                        title: { $0.title },
                        selection: $selectedTab
                    )
                    .padding(.top, 2)

                    switch selectedTab {
                    case .details:
                        detailTab(subject)
                    case .reviews:
                        reviewTab
                    }
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 96)
                } else {
                    emptyState(title: "条目加载失败", symbol: "play.tv", message: errorText ?? "请稍后重试")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 96)
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
            await loadRelations()
        }
        .onChange(of: selectedTab) { tab in
            guard tab == .reviews, !didLoadReviews else { return }
            Task { await loadReviews(reset: true) }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, needsMetadataReload else { return }
            Task {
                await load()
                await loadRelations()
            }
        }
        .sheet(item: $peopleSheet) { sheet in
            NavigationStack {
                AnimePeopleListSheet(sheet: sheet)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .tint(IbiliTheme.accent)
    }

    private func subjectHero(_ subject: AnimeSubjectDTO) -> some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: subject.coverURL, targetPointSize: CGSize(width: 760, height: 760), quality: 72)
                .scaledToFill()
                .frame(height: 356)
                .frame(maxWidth: .infinity)
                .clipped()
                .blur(radius: 22)
                .scaleEffect(1.12)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.10),
                            Color.black.opacity(0.56),
                            IbiliTheme.background.opacity(0.90),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    RemoteImage(url: subject.coverURL, targetPointSize: CGSize(width: 260, height: 370), quality: 86)
                        .frame(width: 130, height: 184)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(subject.displayTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                            .minimumScaleFactor(0.86)
                            .textSelection(.enabled)

                        if subject.displayTitle != subject.name, !subject.name.isEmpty {
                            Text(subject.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }

                        if !subject.date.isEmpty {
                            AnimeHeroCapsule(text: formattedDate(subject.date))
                        }

                        Text(progressText(subject))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)

                        ratingLine(subject)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .center, spacing: 10) {
                    Text(collectionStatsText(subject))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 0)
                    AnimeCollectionStatusPill(label: subject.collectionType > 0 ? subject.collectionLabel : "未收藏")
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ratingLine(_ subject: AnimeSubjectDTO) -> some View {
        HStack(spacing: 8) {
            Text(subject.ratingScore > 0 ? String(format: "%.1f", subject.ratingScore) : "-")
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(IbiliTheme.accent)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: starName(index: index, score: subject.ratingScore))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent.opacity(subject.ratingScore > 0 ? 0.95 : 0.45))
                }
            }
            Text("\(BiliFormat.compactCount(subject.ratingTotal)) 人评")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))
            if subject.rank > 0 {
                Text("#\(subject.rank)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }

    private func actionPanel(_ subject: AnimeSubjectDTO) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                AnimeMetricTile(title: subject.ratingScore > 0 ? String(format: "%.1f", subject.ratingScore) : "-", subtitle: "\(BiliFormat.compactCount(subject.ratingTotal)) 人评分", emphasized: true)
                AnimeMetricTile(title: "\(max(subject.totalEpisodes, Int64(subject.episodes.count)))", subtitle: "集数", emphasized: false)
            }

            HStack(spacing: 10) {
                if let episode = preferredEpisode(subject) {
                    Button {
                        openEpisode(episode, reason: "primary-action")
                    } label: {
                        Label(primaryEpisodeTitle(subject, episode), systemImage: "play.fill")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .tint(IbiliTheme.accent)
                }

                Button {
                    if subject.collectionType == 0 {
                        Task { await updateCollection(3) }
                    }
                } label: {
                    Label(subject.collectionType > 0 ? subject.collectionLabel : "在看", systemImage: "checkmark.circle.fill")
                        .font(.headline.weight(.semibold))
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .tint(IbiliTheme.accent)
            }
        }
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func episodeSection(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选集")
                    .font(.title3.weight(.bold))
                Spacer()
                Text(progressText(subject))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
            }

            if subject.episodes.isEmpty {
                Text("暂无分集数据")
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(subject.episodes.enumerated()), id: \.element.id) { index, episode in
                            AnimeLargeEpisodeCard(
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
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detailTab(_ subject: AnimeSubjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !subject.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section("详情") {
                    VideoDescriptionView(desc: subject.summary, descV2: [])
                }
            }

            if !subject.tags.isEmpty {
                section("标签") {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(subject.tags.prefix(14), id: \.self) { tag in
                            AnimeTagPill(text: tag)
                        }
                    }
                }
            }

            if isLoadingRelations {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载人物资料")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if !relations.characters.isEmpty {
                peopleSection(
                    title: "角色",
                    people: relations.characters.prefix(6).map(AnimePeopleSheet.Entry.character),
                    allSheet: AnimePeopleSheet(title: "角色", entries: relations.characters.map(AnimePeopleSheet.Entry.character))
                )
            }

            if !relations.staff.isEmpty {
                peopleSection(
                    title: "制作人员",
                    people: relations.staff.prefix(6).map(AnimePeopleSheet.Entry.person),
                    allSheet: AnimePeopleSheet(title: "制作人员", entries: relations.staff.map(AnimePeopleSheet.Entry.person))
                )
            }

            if !subject.infoItems.isEmpty {
                section("资料") {
                    VStack(spacing: 0) {
                        ForEach(subject.infoItems.prefix(10)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(item.key)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(IbiliTheme.textSecondary)
                                    .frame(width: 72, alignment: .leading)
                                Text(item.value)
                                    .font(.footnote)
                                    .foregroundStyle(IbiliTheme.textPrimary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            if item.id != subject.infoItems.prefix(10).last?.id {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
            }
        }
    }

    private var reviewTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingReviews, reviews.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
            } else if let reviewErrorText, reviews.isEmpty {
                emptyState(title: "评价加载失败", symbol: "text.bubble", message: reviewErrorText)
                    .frame(maxWidth: .infinity)
                Button("重试") {
                    Task { await loadReviews(reset: true) }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(IbiliTheme.accent)
                .frame(maxWidth: .infinity)
            } else if reviews.isEmpty {
                emptyState(title: "暂无评价", symbol: "text.bubble", message: "Bangumi 暂无公开评价")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(reviews) { review in
                        AnimeSubjectReviewRow(review: review)
                            .onAppear {
                                guard review.id == reviews.last?.id else { return }
                                Task { await loadMoreReviewsIfNeeded() }
                            }
                    }
                    if isLoadingReviews {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
            content()
        }
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func peopleSection(title: String, people: [AnimePeopleSheet.Entry], allSheet: AnimePeopleSheet) -> some View {
        section(title) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(people) { entry in
                    AnimePersonMiniRow(entry: entry)
                }
            }
            if allSheet.entries.count > people.count {
                Button("查看全部") {
                    peopleSheet = allSheet
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IbiliTheme.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .buttonStyle(.plain)
            }
        }
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

    private func loadRelations() async {
        guard subjectID > 0 else { return }
        isLoadingRelations = true
        defer { isLoadingRelations = false }
        do {
            let id = subjectID
            relations = try await Task.detached(priority: .utility) {
                try CoreClient.shared.animeSubjectRelations(subjectID: id)
            }.value
            AppLog.info("anime", "追番人物资料加载完成", metadata: [
                "subjectID": String(id),
                "characters": String(relations.characters.count),
                "staff": String(relations.staff.count),
            ])
        } catch {
            AppLog.warning("anime", "追番人物资料加载失败", metadata: [
                "subjectID": String(subjectID),
                "error": error.localizedDescription,
            ])
        }
    }

    private func loadReviews(reset: Bool) async {
        guard !isLoadingReviews else { return }
        isLoadingReviews = true
        defer {
            isLoadingReviews = false
            didLoadReviews = true
        }
        do {
            let offset: Int64 = reset ? 0 : Int64(reviews.count)
            let id = subjectID
            let page = try await Task.detached(priority: .utility) {
                try CoreClient.shared.animeSubjectReviews(subjectID: id, offset: offset, limit: 20)
            }.value
            reviewsTotal = page.total
            reviews = reset ? page.items : reviews + page.items
            reviewErrorText = nil
        } catch {
            reviewErrorText = error.localizedDescription
            AppLog.error("anime", "追番评价加载失败", error: error, metadata: [
                "subjectID": String(subjectID),
                "offset": String(reset ? 0 : reviews.count),
            ])
        }
    }

    private func loadMoreReviewsIfNeeded() async {
        guard !isLoadingReviews else { return }
        guard reviewsTotal == 0 || Int64(reviews.count) < reviewsTotal else { return }
        await loadReviews(reset: false)
    }

    private func updateCollection(_ collectionType: Int) async {
        guard session.bangumiSession != nil else {
            AppLog.warning("anime", "追番收藏更新跳过：未登录 Bangumi", metadata: [
                "subjectID": String(subjectID),
                "collectionType": String(collectionType),
            ])
            return
        }
        guard collectionType > 0 else { return }
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
        return "开始观看"
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

    private func formattedDate(_ date: String) -> String {
        guard date.count >= 7 else { return date }
        let prefix = String(date.prefix(7)).replacingOccurrences(of: "-", with: " 年 ")
        return "\(prefix) 月"
    }

    private func progressText(_ subject: AnimeSubjectDTO) -> String {
        let current = subject.epStatus > 0 ? "连载至 \(String(format: "%02d", subject.epStatus))" : "连载中"
        let total = subject.totalEpisodes > 0 ? "预定全 \(subject.totalEpisodes) 话" : "\(subject.episodes.count) 话"
        return "\(current) · \(total)"
    }

    private func collectionStatsText(_ subject: AnimeSubjectDTO) -> String {
        let status = subject.collectionType > 0 ? subject.collectionLabel : "未收藏"
        let count = subject.ratingTotal > 0 ? "\(BiliFormat.compactCount(subject.ratingTotal)) 人评分" : "暂无评分"
        return "\(count) / \(status)"
    }

    private func starName(index: Int, score: Double) -> String {
        let value = score / 2.0
        let star = Double(index) + 1.0
        if value >= star { return "star.fill" }
        if value >= star - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

private enum AnimeSubjectTab: String, CaseIterable, Identifiable {
    case details
    case reviews

    var id: String { rawValue }
    var title: String {
        switch self {
        case .details: return "详情"
        case .reviews: return "评价"
        }
    }
}

private struct AnimeHeroCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.20), lineWidth: 0.7))
    }
}

private struct AnimeCollectionStatusPill: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "play.circle")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.90))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.7))
    }
}

private struct AnimeMetricTile: View {
    let title: String
    let subtitle: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(emphasized ? IbiliTheme.accent : IbiliTheme.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(IbiliTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(emphasized ? IbiliTheme.accent.opacity(0.10) : Color(.tertiarySystemFill))
        )
    }
}

private struct AnimeLargeEpisodeCard: View {
    let episode: AnimeEpisodeDTO
    let index: Int
    let stateLabel: String
    let onTap: () -> Void

    private var hasState: Bool { !stateLabel.isEmpty }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if hasState {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                    }
                    Text(String(format: "%02d", index))
                        .font(.headline.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(hasState ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(episode.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hasState ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if hasState {
                    Text(stateLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(width: 132, height: 96, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hasState ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(hasState ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AnimeTagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IbiliTheme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(IbiliTheme.textSecondary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct AnimePersonMiniRow: View {
    let entry: AnimePeopleSheet.Entry

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: entry.image, targetPointSize: CGSize(width: 96, height: 96), quality: 76)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AnimeSubjectReviewRow: View {
    let review: AnimeSubjectReviewDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RemoteImage(url: review.user.avatar, targetPointSize: CGSize(width: 80, height: 80), quality: 72)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.user.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if review.rating > 0 {
                            Label("\(review.rating)", systemImage: "star.fill")
                                .foregroundStyle(IbiliTheme.accent)
                        }
                        Text(BiliFormat.relativeDate(review.updatedAt))
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                    .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
            }

            Text(review.content)
                .font(.body)
                .foregroundStyle(IbiliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AnimePeopleSheet: Identifiable {
    enum Entry: Identifiable, Hashable {
        case character(AnimeCharacterDTO)
        case person(AnimePersonDTO)

        var id: String {
            switch self {
            case .character(let item): return "character-\(item.id)-\(item.role)"
            case .person(let item): return "person-\(item.id)-\(item.role)"
            }
        }

        var image: String {
            switch self {
            case .character(let item): return item.image
            case .person(let item): return item.image
            }
        }

        var name: String {
            switch self {
            case .character(let item): return item.displayName
            case .person(let item): return item.displayName
            }
        }

        var subtitle: String {
            switch self {
            case .character(let item):
                let actor = item.actors.first?.displayName ?? ""
                return [item.role, actor].filter { !$0.isEmpty }.joined(separator: " · ")
            case .person(let item):
                return item.role
            }
        }
    }

    let title: String
    let entries: [Entry]
    var id: String { title }
}

private struct AnimePeopleListSheet: View {
    let sheet: AnimePeopleSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(sheet.entries) { entry in
            AnimePersonMiniRow(entry: entry)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .background(IbiliTheme.background)
        .navigationTitle(sheet.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }
}
