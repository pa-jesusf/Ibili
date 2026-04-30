import SwiftUI

/// Sheet listing the parts (多 P) of a single video.
struct VideoPagesPicker: View {
    let pages: [VideoPageDTO]
    let currentCid: Int64
    let onPick: (Int64) -> Void

    var body: some View {
        NavigationStack {
            List(pages) { page in
                Button {
                    onPick(page.cid)
                } label: {
                    HStack(spacing: 12) {
                        Text("P\(page.page)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(page.cid == currentCid ? IbiliTheme.accent : IbiliTheme.textSecondary)
                            .frame(width: 36, alignment: .leading)
                        Text(page.part)
                            .font(.subheadline)
                            .foregroundStyle(page.cid == currentCid ? IbiliTheme.accent : IbiliTheme.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if page.durationSec > 0 {
                            Text(BiliFormat.duration(page.durationSec))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(IbiliTheme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
