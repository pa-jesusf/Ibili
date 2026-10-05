import SwiftUI

/// Shared by the dynamic feed, forwarded posts, and dynamic details.
struct DynamicVideoTile: View {
    let video: DynamicVideoDTO
    let contentWidth: CGFloat
    var showsPlayButton = false

    var body: some View {
        let height = max(1, contentWidth * 9 / 16)
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: video.cover, contentMode: .fill,
                        targetPointSize: CGSize(width: contentWidth, height: height), quality: 80)
                .frame(width: contentWidth, height: height)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            if showsPlayButton {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: contentWidth, height: height)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(video.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !video.playLabel.isEmpty {
                        Label(video.playLabel, systemImage: "play.fill")
                            .accessibilityLabel("\(video.playLabel)播放")
                    }
                    if !video.danmakuLabel.isEmpty {
                        Label(video.danmakuLabel, systemImage: "text.bubble")
                            .accessibilityLabel("\(video.danmakuLabel)弹幕")
                    }
                    if video.playLabel.isEmpty, video.danmakuLabel.isEmpty, !video.statLabel.isEmpty {
                        Text(video.statLabel)
                    }
                    Spacer(minLength: 0)
                    if !video.durationLabel.isEmpty {
                        Text(video.durationLabel)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.black.opacity(0.5)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            }
            .padding(10)
            .frame(width: contentWidth, alignment: .leading)
        }
        .frame(width: contentWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}
