import SwiftUI

/// Top-level search screen. Owns the `NavigationStack`, the system
/// `.searchable` field, and switches between the landing view (history
/// + 分区) and the result grid. Designed to feel native on iOS 16+
/// — taps on the toolbar magnifying glass slide into a long search
/// bar exactly the way Apple Music / App Store / Photos do.
struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @StateObject private var history = SearchHistoryStore()
    @State private var isFiltersSheetPresented: Bool = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .background(IbiliTheme.background)
                .navigationTitle("搜索")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .tint(IbiliTheme.accent)
        .searchable(
            text: $vm.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索视频、UP主、番剧"
        )
        .focused($isSearchFocused)
        .onSubmit(of: .search) {
            history.push(vm.query)
            vm.submit()
        }
        .sheet(isPresented: $isFiltersSheetPresented) {
            SearchFiltersSheet(vm: vm)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.hasSubmittedQuery,
           !vm.submittedQuery.isEmpty,
           vm.query == vm.submittedQuery {
            VStack(spacing: 0) {
                SearchTypeBar(vm: vm)
                Divider().opacity(0.4)
                SearchResultsView(vm: vm)
            }
        } else {
            SearchLandingView(vm: vm, history: history) { query, category in
                isSearchFocused = false
                vm.selectedCategory = category
                vm.query = query
                history.push(query)
                vm.submit()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if vm.hasSubmittedQuery,
           !vm.submittedQuery.isEmpty,
           vm.query == vm.submittedQuery {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isFiltersSheetPresented = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .foregroundStyle(IbiliTheme.accent)
            }
        }
    }
}
