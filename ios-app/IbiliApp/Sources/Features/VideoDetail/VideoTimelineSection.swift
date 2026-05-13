import SwiftUI

struct VideoTimelineSection: View {
    let viewPoints: [VideoViewPointDTO]
    let currentSeconds: Double
    let onSeek: (Int64) -> Void

    private var currentID: VideoViewPointDTO.ID? {
        guard currentSeconds.isFinite else { return nil }
        let second = Int64(currentSeconds.rounded(.down))
        return viewPoints.first { second >= $0.fromSec && second < $0.toSec }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(IbiliTheme.accent)
                Text("时间轴")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewPoints) { item in
                        let isCurrent = item.id == currentID
                        Button {
                            onSeek(item.fromSec)
                        } label: {
                            TimelineCard(item: item, isCurrent: isCurrent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }
}

private struct TimelineCard: View {
    let item: VideoViewPointDTO
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                RemoteImage(
                    url: item.imageUrl,
                    targetPointSize: CGSize(width: 150, height: 84),
                    quality: 75
                )
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if isCurrent {
                    Text("正在播放")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(IbiliTheme.accent))
                        .padding(6)
                }
            }

            Text(item.content.isEmpty ? "未命名段落" : item.content)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isCurrent ? IbiliTheme.accent : IbiliTheme.textPrimary)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)

            Text("\(BiliFormat.duration(item.fromSec)) - \(BiliFormat.duration(item.toSec))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(IbiliTheme.textSecondary)
                .frame(width: 150, alignment: .leading)
        }
        .padding(8)
        .frame(width: 166, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? IbiliTheme.accent.opacity(0.12) : IbiliTheme.background)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? IbiliTheme.accent : Color.white.opacity(0.08), lineWidth: isCurrent ? 1.4 : 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
