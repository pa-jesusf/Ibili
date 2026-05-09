import SwiftUI

struct PgcSeasonIntroView: View {
    let season: PgcSeasonDTO
    let currentEpID: Int64
    let onPickEpisode: (PgcEpisodeDTO) -> Void

    @State private var showsEpisodeSheet = false

    private var currentEpisode: PgcEpisodeDTO? {
        if currentEpID > 0, let matched = season.episodes.first(where: { $0.epID == currentEpID }) {
            return matched
        }
        return season.episodes.first
    }

    private var title: String {
        season.seasonTitle.isEmpty ? season.title : season.seasonTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !season.evaluate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VideoDescriptionView(desc: season.evaluate, descV2: [])
            }
            episodeSection
            metadataSection
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: season.cover,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: 168, height: 224),
                        quality: 82)
                .frame(width: 84, height: 112)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Text("评分 \(displayScore)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IbiliTheme.accent)
                    if !season.newEpDesc.isEmpty {
                        Text(season.newEpDesc)
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                let meta = [season.areas.joined(separator: " · "), season.subtitle]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Label(BiliFormat.compactCount(season.stat.view), systemImage: "play.fill")
                    Label(BiliFormat.compactCount(season.stat.danmaku), systemImage: "text.bubble.fill")
                }
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选集")
                        .font(.headline)
                        .foregroundStyle(IbiliTheme.textPrimary)
                    Text(episodeSummary)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    showsEpisodeSheet = true
                } label: {
                    Label("全部", systemImage: "rectangle.stack")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(IbiliTheme.accent)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(season.episodes.enumerated()), id: \.element.id) { index, episode in
                            PgcEpisodeChip(
                                episode: episode,
                                index: index + 1,
                                isCurrent: episode.epID == currentEpisode?.epID
                            ) {
                                guard episode.epID != currentEpisode?.epID else { return }
                                onPickEpisode(episode)
                            }
                            .id(episode.epID)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .background(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: true))
                .overlay(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: false))
                .onAppear {
                    guard let id = currentEpisode?.epID else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: currentEpID) { _ in
                    guard let id = currentEpisode?.epID else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
        .sheet(isPresented: $showsEpisodeSheet) {
            PgcEpisodeSheet(season: season, currentEpID: currentEpisode?.epID ?? 0) { episode in
                showsEpisodeSheet = false
                guard episode.epID != currentEpisode?.epID else { return }
                onPickEpisode(episode)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !season.actors.isEmpty {
                metadataRow(title: "声优/演员", value: season.actors)
            }
            if !season.upName.isEmpty {
                metadataRow(title: "出品", value: season.upName)
            }
        }
    }

    private func metadataRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IbiliTheme.textSecondary)
            Text(value)
                .font(.footnote)
                .foregroundStyle(IbiliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IbiliTheme.surface))
    }

    private var displayScore: String {
        let score = season.ratingScore.trimmingCharacters(in: .whitespacesAndNewlines)
        return score.isEmpty || score == "0" || score == "0.0" ? "-" : score
    }

    private var episodeSummary: String {
        guard let currentEpisode else {
            return "共 \(season.episodes.count) 集"
        }
        let label = currentEpisode.longTitle.isEmpty ? currentEpisode.title : currentEpisode.longTitle
        if label.isEmpty {
            return "正在播放第 \(currentIndex + 1) 集 · 共 \(season.episodes.count) 集"
        }
        return "正在播放 \(label) · 共 \(season.episodes.count) 集"
    }

    private var currentIndex: Int {
        season.episodes.firstIndex { $0.epID == currentEpisode?.epID } ?? 0
    }
}

private struct PgcEpisodeChip: View {
    let episode: PgcEpisodeDTO
    let index: Int
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index))
                        .font(.caption2.weight(.bold).monospacedDigit())
                    if isCurrent {
                        Image(systemName: "waveform")
                            .imageScale(.small)
                    }
                }
                .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 124, height: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isCurrent ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var displayTitle: String {
        let title = episode.longTitle.isEmpty ? episode.title : episode.longTitle
        return title.isEmpty ? "第 \(index) 集" : title
    }
}

private struct PgcEpisodeSheet: View {
    let season: PgcSeasonDTO
    let currentEpID: Int64
    let onPick: (PgcEpisodeDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var scrollContext = InterruptibleScrollContext()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    PlayerSwipeBackExclusionZone(includeEnclosingScrollView: true)
                        .frame(height: 0)
                    InterruptibleScrollCapture(context: scrollContext)
                        .frame(width: 0, height: 0)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(season.episodes.enumerated()), id: \.element.id) { index, episode in
                            PgcEpisodeSheetRow(
                                episode: episode,
                                index: index + 1,
                                isCurrent: episode.epID == currentEpID,
                                fallbackCover: season.cover
                            )
                            .id(episode.epID)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if episode.epID == currentEpID {
                                    dismiss()
                                } else {
                                    onPick(episode)
                                    dismiss()
                                }
                            }
                            if index < season.episodes.count - 1 {
                                Divider().padding(.leading, 132)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .navigationTitle(season.seasonTitle.isEmpty ? season.title : season.seasonTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            scrollToCurrent(proxy)
                        } label: {
                            Label("定位", systemImage: "scope")
                                .labelStyle(.titleAndIcon)
                                .font(.footnote.weight(.medium))
                        }
                        .disabled(currentEpID <= 0)
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollToCurrent(proxy)
                    }
                }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard currentEpID > 0 else { return }
        proxy.interruptingScrollTo(
            currentEpID,
            anchor: .center,
            context: scrollContext,
            animation: .easeInOut(duration: 0.25)
        )
    }
}

private struct PgcEpisodeSheetRow: View {
    let episode: PgcEpisodeDTO
    let index: Int
    let isCurrent: Bool
    let fallbackCover: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(
                    url: episode.cover.isEmpty ? fallbackCover : episode.cover,
                    contentMode: .fill,
                    targetPointSize: CGSize(width: 240, height: 150),
                    quality: 75
                )
                .frame(width: 120, height: 75)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(IbiliTheme.accent, lineWidth: isCurrent ? 1.5 : 0)
                )

                if episode.durationSec > 0 {
                    Text(BiliFormat.duration(episode.durationSec))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(String(format: "%02d", index))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    if isCurrent {
                        Text("正在播放")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(IbiliTheme.accent.opacity(0.14)))
                    }
                }
                .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if episode.pubTime > 0 {
                    Text(BiliFormat.relativeDate(episode.pubTime))
                        .font(.caption2)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? IbiliTheme.accent.opacity(0.06) : .clear)
    }

    private var displayTitle: String {
        let title = episode.longTitle.isEmpty ? episode.title : episode.longTitle
        return title.isEmpty ? "第 \(index) 集" : title
    }
}
