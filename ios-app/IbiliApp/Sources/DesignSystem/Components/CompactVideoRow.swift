import SwiftUI

/// Compact horizontal video row used by:
///   • 相关视频 列表 (`VideoDetail/RelatedVideoList`)
///   • 我的 → 历史 / 收藏 / 稍后再看 二级页
///   • Anywhere else a video needs a vertical-list presentation
///     rather than the home/search 2-up grid.
///
/// Visual: 16:10 cover on the left with optional duration pill,
/// title + author + stats stacked on the right. Apple-feeling rhythm:
/// 8pt vertical padding, 12pt cover-to-text gap.
///
/// Tap handling lives at the call-site so callers can choose between
/// `Button { … } label: { CompactVideoRow(...) }` or wrapping in
/// `NavigationLink`. We expose a `progress` knob (0…1) so the
/// "history" surface can render the upstream resume bar without
/// needing a second component.
struct CompactVideoRow: View {
    let cover: String
    let title: String
    let author: String
    let durationSec: Int64
    let play: Int64
    let danmaku: Int64
    /// Optional resume-progress (0…1). Zero hides the bar entirely.
    var progress: Double = 0
    /// Optional override for the duration pill (e.g. "已看完", "看到 3 分钟").
    /// Falls back to formatted duration when nil.
    var durationOverride: String? = nil

    var body: some View {
        MediaRowView(
            model: MediaCardRenderModel(
                identity: FeedStableIdentity(aid: title.hashStableInt64, bvid: cover),
                title: title,
                cover: cover,
                author: author,
                durationSec: durationSec,
                play: play,
                danmaku: danmaku,
                imageQuality: 75,
                meta: .standard
            ),
            progress: progress,
            durationOverride: durationOverride
        )
    }
}

private extension String {
    var hashStableInt64: Int64 {
        var result: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            result ^= UInt64(byte)
            result &*= 1_099_511_628_211
        }
        return Int64(bitPattern: result)
    }
}
