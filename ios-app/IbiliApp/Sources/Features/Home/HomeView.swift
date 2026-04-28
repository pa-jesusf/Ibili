import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
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
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, (geo.size.width - totalSpacing) / CGFloat(cols))
            let gridItems = Array(
                repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                LazyVGrid(columns: gridItems, spacing: 16) {
                    ForEach(vm.items) { item in
                        NavigationLink(value: item) {
                            VideoCardView(
                                item: item,
                                cardWidth: cardW,
                                imageQuality: settings.resolvedImageQuality()
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.aid == vm.items.last?.aid {
                                Task { await vm.loadMore() }
                            }
                        }
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
        }
    }
}
