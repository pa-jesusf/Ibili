import SwiftUI

/// Sheet listing every episode in a 合集 (UGC season). Sections are
/// flattened when only one section exists; otherwise rendered with
/// section headers.
///
/// Visual: reuses the same row idiom as the related-video list — cover
/// thumbnail on the left with duration overlay, title + meta stacked on
/// the right. The currently-playing episode gets a subtle accent
/// background + a small "正在播放" pill so it stands out without
/// breaking the rhythm of the rest of the list. Tapping any other row
/// dismisses the sheet and routes through `DeepLinkRouter` so the new
/// video replaces the player (consistent with related-tap behaviour).
///
/// On appear we scroll the current episode into view, and offer a
/// "定位" toolbar button so users who scroll away can jump back.
struct UgcSeasonSheet: View {
    let season: UgcSeasonDTO
    let currentCid: Int64
    let onPick: (_ aid: Int64, _ bvid: String, _ cid: Int64) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(season.sections.enumerated()), id: \.element.id) { si, section in
                            if season.sections.count > 1 {
                                HStack {
                                    Text(section.title.isEmpty ? "正片" : section.title)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(IbiliTheme.textSecondary)
                                    Spacer()
                                    Text("\(section.episodes.count) 集")
                                        .font(.caption2)
                                        .foregroundStyle(IbiliTheme.textSecondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, si == 0 ? 4 : 16)
                                .padding(.bottom, 6)
                            }
                            ForEach(Array(section.episodes.enumerated()), id: \.element.id) { ei, ep in
                                EpisodeRow(
                                    episode: ep,
                                    index: ei + 1,
                                    isCurrent: ep.cid == currentCid
                                )
                                .id(ep.cid)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if ep.cid == currentCid {
                                        dismiss()
                                    } else {
                                        onPick(ep.aid, ep.bvid, ep.cid)
                                        dismiss()
                                    }
                                }
                                if ei < section.episodes.count - 1 {
                                    Divider().padding(.leading, 132)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .navigationTitle(season.title.isEmpty ? "合集" : season.title)
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
                        .disabled(currentCid == 0)
                    }
                }
                .onAppear {
                    // Defer until the lazy stack has had a chance to
                    // realise the current row, otherwise scrollTo silently
                    // no-ops on the first frame.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollToCurrent(proxy)
                    }
                }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard currentCid != 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(currentCid, anchor: .center)
        }
    }
}

/// One row in the 合集 list. Visual mirrors the related-row layout —
/// 120×75 cover with duration overlay, title + index meta on the right.
/// `isCurrent` switches on a subtle accent stroke / "正在播放" pill so
/// the user can spot where they are at a glance.
private struct EpisodeRow: View {
    let episode: UgcSeasonEpisodeDTO
    let index: Int
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(
                    url: episode.cover,
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
                .overlay(alignment: .topLeading) {
                    if isCurrent {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .imageScale(.small)
                            Text("播放中")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(IbiliTheme.accent))
                        .padding(4)
                    }
                }

                if episode.durationSec > 0 {
                    Text(BiliFormat.duration(episode.durationSec))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%02d", index))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textSecondary)
                Text(episode.title.isEmpty ? "P\(index)" : episode.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? IbiliTheme.accent.opacity(0.06) : .clear)
    }
}

