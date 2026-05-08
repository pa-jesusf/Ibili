import SwiftUI
import UIKit

/// Grid of search-result cards. Reuses the same column-sizing logic as
/// the home feed so user preferences flow through, but disables the
/// home's top-trailing duration variant since search cards already
/// include a denser bottom info area.
struct SearchResultsView: View {
    @ObservedObject var vm: SearchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var pageInputText: String = ""
    @State private var isPageInputPresented: Bool = false
    @State private var scrollID: UUID = UUID()
    @StateObject private var scrollContext = InterruptibleScrollContext()

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

            ScrollViewReader { scrollProxy in
                ScrollView {
                    InterruptibleScrollCapture(context: scrollContext)
                        .frame(width: 0, height: 0)
                    Color.clear.frame(height: 0).id("searchResultsTop")

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
                            resultButton(for: item, cardWidth: cardW)
                                .onAppear {
                                    prefetchCovers(around: item, cardWidth: cardW)
                                }
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 8)

                    searchPaginationBar
                        .padding(.horizontal, hPad)
                        .padding(.bottom, 20)
                }
                .onChange(of: scrollID) { _ in
                    scrollProxy.interruptingScrollTo(
                        "searchResultsTop",
                        anchor: .top,
                        context: scrollContext,
                        animation: .easeOut(duration: 0.2)
                    )
                }
            }
        }
        .alert("跳转到页码", isPresented: $isPageInputPresented) {
            TextField("页码", text: $pageInputText)
                .keyboardType(.numberPad)
            Button("跳转") {
                if let target = Int64(pageInputText), target >= 1 {
                    vm.loadPage(target)
                    scrollID = UUID()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .modifier(ProMotionScrollHint())
    }

    @ViewBuilder
    private var searchPaginationBar: some View {
        if vm.isLoading && !vm.results.isEmpty {
            ProgressView().padding(.vertical, 16)
        } else {
            HStack(spacing: 12) {
                Button {
                    vm.loadPreviousPage()
                    scrollID = UUID()
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                }
                .disabled(vm.page <= 1)

                Spacer(minLength: 8)

                Button {
                    pageInputText = String(max(vm.page, 1))
                    isPageInputPresented = true
                } label: {
                    VStack(spacing: 2) {
                        Text("第 \(max(vm.page, 1)) 页")
                            .font(.subheadline.weight(.semibold))
                        if vm.totalResults > 0 {
                            Text("约 \(BiliFormat.compactCount(vm.totalResults)) 个结果")
                                .font(.caption)
                                .foregroundStyle(IbiliTheme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    vm.loadNextPage()
                    scrollID = UUID()
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!vm.hasMore)
            }
            .buttonStyle(.bordered)
            .tint(IbiliTheme.accent)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func resultButton(for item: SearchResultItem, cardWidth: CGFloat) -> some View {
        switch item {
        case .video(let video):
            Button {
                router.open(feedItem(from: video))
            } label: {
                SearchResultCardView(
                    item: video,
                    cardWidth: cardWidth,
                    imageQuality: settings.resolvedImageQuality(),
                    meta: settings.searchCardMeta
                )
            }
            .buttonStyle(.plain)
        case .live(let live):
            Button {
                router.openLive(
                    roomID: live.roomID,
                    title: live.title,
                    cover: live.cover,
                    anchorName: live.uname
                )
            } label: {
                SearchLiveResultCardView(
                    item: live,
                    cardWidth: cardWidth,
                    imageQuality: settings.resolvedImageQuality()
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func prefetchCovers(around item: SearchResultItem, cardWidth: CGFloat) {
        let lookahead = 18
        guard let idx = vm.results.firstIndex(where: { $0.id == item.id }) else { return }
        let start = min(idx + 1, vm.results.count)
        let end = min(start + lookahead, vm.results.count)
        guard start < end else { return }
        let covers = vm.results[start..<end].map { result in
            switch result {
            case .video(let video): return video.cover
            case .live(let live): return live.cover
            }
        }
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
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
            danmaku: result.danmaku,
            pubdate: result.pubdate
        )
    }
}
