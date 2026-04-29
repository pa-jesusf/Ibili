import SwiftUI
import UIKit

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @StateObject private var prefetch = FeedPrefetchCoordinator()
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().tint(IbiliTheme.accent)
            } else if let err = vm.errorText, vm.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("重试") { Task { await vm.refresh() } }
                        .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                }.padding()
            } else {
                feedGrid
            }
        }
        .task { await vm.loadInitial() }
        .refreshable { await vm.refresh() }
    }

    private var feedGrid: some View {
        GeometryReader { geo in
            let cols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let usesTopTrailingDuration = UIDevice.current.userInterfaceIdiom == .phone && cols >= 3
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
                LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                    ForEach(vm.items) { item in
                        NavigationLink(value: item) {
                            VideoCardView(
                                item: item,
                                cardWidth: cardW,
                                imageQuality: settings.resolvedImageQuality(),
                                showsDurationAtTopTrailing: usesTopTrailingDuration
                            )
                        }
                        .buttonStyle(TouchDownReportingButtonStyle {
                            prefetch.touchDown(item)
                        })
                        .onAppear {
                            prefetch.cardAppeared(item, allItems: vm.items)
                            if item.aid == vm.items.last?.aid {
                                Task { await vm.loadMore() }
                            }
                        }
                        .onDisappear { prefetch.cardDisappeared(item) }
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, 8)

                if vm.isLoading && !vm.items.isEmpty {
                    ProgressView().padding()
                }
            }
            .navigationDestination(for: FeedItemDTO.self) { item in
                PlayerView(item: item)
            }
            .modifier(ProMotionScrollHint())
            .onAppear {
                prefetch.update(preferredQn: Int64(settings.resolvedPreferredVideoQn()))
            }
        }
    }
}
