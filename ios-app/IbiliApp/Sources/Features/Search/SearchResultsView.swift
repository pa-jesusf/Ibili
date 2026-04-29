import SwiftUI
import UIKit

/// Grid of search-result cards. Reuses the same column-sizing logic as
/// the home feed so user preferences flow through, but disables the
/// home's top-trailing duration variant since search cards already
/// include a denser bottom info area.
struct SearchResultsView: View {
    @ObservedObject var vm: SearchViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if vm.results.isEmpty && vm.isLoading {
                ProgressView().tint(IbiliTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = vm.errorText, vm.results.isEmpty {
                emptyState(systemImage: "wifi.exclamationmark", text: err, retry: true)
            } else if !vm.selectedType.isImplemented {
                emptyState(systemImage: "hourglass", text: "「\(vm.selectedType.label)」搜索敬请期待")
            } else if vm.results.isEmpty {
                emptyState(systemImage: "magnifyingglass", text: "暂无相关结果")
            } else {
                resultsGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IbiliTheme.background)
    }

    private var resultsGrid: some View {
        GeometryReader { geo in
            let cols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, floor((geo.size.width - totalSpacing) / CGFloat(cols)))
            let rowSpacing: CGFloat = 14
            let gridItems = Array(
                repeating: GridItem(.fixed(cardW), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                if vm.totalResults > 0 {
                    HStack {
                        Text("约 \(BiliFormat.compactCount(vm.totalResults)) 个结果")
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, hPad)
                    .padding(.top, 4)
                }

                LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                    ForEach(vm.results) { item in
                        NavigationLink(value: feedItem(from: item)) {
                            SearchResultCardView(
                                item: item,
                                cardWidth: cardW,
                                imageQuality: settings.resolvedImageQuality()
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == vm.results.last?.id {
                                vm.loadMore()
                            }
                        }
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 8)

                if vm.isLoading && !vm.results.isEmpty {
                    ProgressView().padding()
                }
            }
        }
    }

    private func emptyState(
        systemImage: String,
        text: String,
        retry: Bool = false
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(IbiliTheme.textSecondary)
            if retry {
                Button("重试") { vm.submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(IbiliTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func feedItem(from result: SearchVideoItemDTO) -> FeedItemDTO {
        FeedItemDTO(
            aid: result.aid,
            bvid: result.bvid,
            cid: result.cid,
            title: result.title,
            cover: result.cover,
            author: result.author,
            durationSec: result.durationSec,
            play: result.play,
            danmaku: result.danmaku
        )
    }
}
