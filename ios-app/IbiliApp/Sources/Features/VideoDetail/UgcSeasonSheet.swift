import SwiftUI

/// Sheet listing every episode in a 合集 (UGC season). Sections are
/// flattened when only one section exists; otherwise rendered with
/// section headers.
struct UgcSeasonSheet: View {
    let season: UgcSeasonDTO
    let currentCid: Int64
    let onPick: (_ aid: Int64, _ bvid: String, _ cid: Int64) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(season.sections) { section in
                    if season.sections.count > 1 {
                        Section(section.title.isEmpty ? "正片" : section.title) {
                            ForEach(section.episodes) { ep in
                                row(ep)
                            }
                        }
                    } else {
                        ForEach(section.episodes) { ep in
                            row(ep)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(season.title.isEmpty ? "合集" : season.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func row(_ ep: UgcSeasonEpisodeDTO) -> some View {
        Button {
            onPick(ep.aid, ep.bvid, ep.cid)
        } label: {
            HStack(spacing: 12) {
                if ep.cid == currentCid {
                    Image(systemName: "play.fill")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.accent)
                        .frame(width: 16)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.title)
                        .font(.subheadline)
                        .foregroundStyle(ep.cid == currentCid ? IbiliTheme.accent : IbiliTheme.textPrimary)
                        .lineLimit(2)
                    if ep.durationSec > 0 {
                        Text(BiliFormat.duration(ep.durationSec))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
