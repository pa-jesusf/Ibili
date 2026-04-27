import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()

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
                feedList
            }
        }
        .task { await vm.loadInitial() }
        .refreshable { await vm.refresh() }
    }

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(vm.items) { item in
                    NavigationLink(value: item) {
                        VideoCardView(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.aid == vm.items.last?.aid {
                            Task { await vm.loadMore() }
                        }
                    }
                }
                if vm.isLoading && !vm.items.isEmpty {
                    ProgressView().padding()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationDestination(for: FeedItemDTO.self) { item in
            PlayerView(item: item)
        }
    }
}
