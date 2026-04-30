import SwiftUI

/// Compact "合集 / 多 P" entry on the detail page. Tapping it presents
/// a sheet that lets the user pick an episode (合集) or a part (多 P).
struct VideoSeasonCard: View {
    enum Source {
        case season(UgcSeasonDTO, currentCid: Int64)
        case pages([VideoPageDTO], currentCid: Int64)
    }

    let source: Source
    let onPick: (_ aid: Int64?, _ bvid: String?, _ cid: Int64) -> Void

    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: title.contains("合集") ? "rectangle.stack.fill" : "list.bullet.rectangle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(IbiliTheme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textSecondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IbiliTheme.surface))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $presented) {
            sheet
        }
    }

    private var title: String {
        switch source {
        case .season(let s, _): return s.title.isEmpty ? "合集" : s.title
        case .pages: return "选集"
        }
    }

    private var subtitle: String {
        switch source {
        case .season(let s, _): return "共 \(s.epCount > 0 ? s.epCount : Int32(s.sections.flatMap(\.episodes).count)) 集"
        case .pages(let pages, _): return "共 \(pages.count) P"
        }
    }

    @ViewBuilder
    private var sheet: some View {
        switch source {
        case .season(let s, let currentCid):
            UgcSeasonSheet(season: s, currentCid: currentCid) { aid, bvid, cid in
                presented = false
                onPick(aid, bvid, cid)
            }
            .presentationDetents([.medium, .large])
        case .pages(let pages, let currentCid):
            VideoPagesPicker(pages: pages, currentCid: currentCid) { cid in
                presented = false
                onPick(nil, nil, cid)
            }
            .presentationDetents([.medium])
        }
    }
}
