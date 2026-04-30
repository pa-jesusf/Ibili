import SwiftUI

/// Reusable cover image for a video card, with the canonical Bilibili
/// metadata overlays (play count + duration). Used by both the home
/// feed and the search-results grid so the cover treatment stays
/// consistent.
///
/// Caller controls cover sizing by passing `width`; the height follows
/// the fixed 16:10 aspect we use across the app. Caller must apply
/// outer corner clipping — this view intentionally does not own the
/// rounded shape so it can be combined with a card chrome that clips
/// the bottom info area too.
struct VideoCoverView: View {
    let cover: String
    let width: CGFloat
    let imageQuality: Int?
    let playCount: Int64
    let durationSec: Int64
    let durationPlacement: DurationPlacement
    /// When false the play-count chip is hidden. Defaults to true so
    /// existing call sites keep their previous behaviour.
    var showPlayCount: Bool = true
    /// When false the duration chip is hidden regardless of placement.
    var showDuration: Bool = true

    enum DurationPlacement {
        /// Duration sits next to the play-count chip on the bottom row.
        case bottomTrailing
        /// Duration is pinned to the upper-right corner; the bottom row
        /// only contains the play-count chip. Useful on narrow cards
        /// where the bottom row would otherwise feel cramped.
        case topTrailing
    }

    static let aspectRatio: CGFloat = 16.0 / 10.0

    private var height: CGFloat { (width / Self.aspectRatio).rounded() }

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(
                url: cover,
                contentMode: .fill,
                targetPointSize: CGSize(width: width, height: height),
                quality: imageQuality
            )
            .frame(width: width, height: height)
            .clipped()

            if durationPlacement == .topTrailing {
                VStack {
                    HStack {
                        Spacer()
                        if showDuration, durationSec > 0 {
                            OverlayChip(text: BiliFormat.duration(durationSec), isMonospaced: true)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if showPlayCount {
                    OverlayChip(systemImage: "play.fill", text: BiliFormat.compactCount(playCount))
                }
                Spacer(minLength: 8)
                if showDuration, durationPlacement == .bottomTrailing, durationSec > 0 {
                    OverlayChip(text: BiliFormat.duration(durationSec), isMonospaced: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: width, height: height)
    }
}
