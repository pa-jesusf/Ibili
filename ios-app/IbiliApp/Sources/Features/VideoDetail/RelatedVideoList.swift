import SwiftUI

/// "相关视频" tab content.
///
/// Visual: vertical list of compact rows (cover left, title + meta right)
/// rather than the home/search 2-up grid. Pagination: the upstream
/// `archive/related` endpoint is one-shot, so once those exhaust the VM
/// falls back to the home feed for additional rows. Tap → `onTap`
/// (the parent forwards into the deep-link router so the new video
/// opens on top of the current player, mirroring an in-app jump).
struct RelatedVideoList: View {
    let items: [RelatedVideoItemDTO]
    let isLoadingMore: Bool
    let isEnd: Bool
    let onTap: (FeedItemDTO) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        if items.isEmpty {
            emptyState(title: "暂无相关视频", symbol: "rectangle.stack.badge.minus")
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onTap(adapt(item))
                    } label: {
                        RelatedRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Trigger more when the third-from-last row appears
                        // so the list feels seamless on slower networks.
                        if !isEnd, index >= max(0, items.count - 3) {
                            onReachEnd()
                        }
                    }
                    if index < items.count - 1 {
                        Divider().padding(.leading, 132)
                    }
                }
                if isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 14)
                } else if isEnd {
                    HStack { Spacer(); Text("已经到底了").font(.caption).foregroundStyle(.secondary); Spacer() }
                        .padding(.vertical, 14)
                }
            }
        }
    }

    private func adapt(_ r: RelatedVideoItemDTO) -> FeedItemDTO {
        FeedItemDTO(
            aid: r.aid,
            bvid: r.bvid,
            cid: r.cid,
            title: r.title,
            cover: r.cover,
            author: r.author,
            durationSec: r.durationSec,
            play: r.play,
            danmaku: r.danmaku
        )
    }
}

/// Single row: cover left (16:10) with duration overlay, title + UP +
/// stats stacked on the right. Sized for an Apple-feeling rhythm:
/// 8pt vertical padding, 12pt cover-to-text gap, 13pt title, 11pt meta.
private struct RelatedRow: View {
    let item: RelatedVideoItemDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: item.cover,
                            contentMode: .fill,
                            targetPointSize: CGSize(width: 240, height: 150),
                            quality: 75)
                    .frame(width: 120, height: 75)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if item.durationSec > 0 {
                    Text(BiliFormat.duration(item.durationSec))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !item.author.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .imageScale(.small)
                        Text(item.author)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
                }
                HStack(spacing: 12) {
                    if item.play > 0 {
                        Label(BiliFormat.compactCount(item.play), systemImage: "play.fill")
                    }
                    if item.danmaku > 0 {
                        Label(BiliFormat.compactCount(item.danmaku), systemImage: "text.bubble")
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
