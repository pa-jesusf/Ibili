import SwiftUI

/// Top-level search screen. Owns the `NavigationStack`, the system search
/// field, and switches between the landing view (history + 分区) and the
/// result grid.
struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @StateObject private var history = SearchHistoryStore()
    @State private var isFiltersSheetPresented: Bool = false
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.rootContentNavigation) private var rootContentNavigation

    var body: some View {
        NavigationStack {
            content
            .background(IbiliTheme.background)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationTracePage("SearchRoot", metadata: [
                "transitionWorld": "root-content-child",
            ])
        }
        .searchable(text: $vm.query, prompt: "搜索视频、UP主、番剧")
        .environment(\.openURL, OpenURLAction { url in
            rootContentNavigation.handle(url, router: router)
        })
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search, submitCurrentQuery)
        .tint(IbiliTheme.accent)
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
                vm.selectedCategory = category
                vm.query = query
                history.push(query)
                vm.submit()
                dismissSearch()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if vm.hasSubmittedQuery,
           !vm.submittedQuery.isEmpty,
           vm.query == vm.submittedQuery,
           vm.selectedType.hasFilters {
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

    private func submitCurrentQuery() {
        NavigationTrace.withUserAction("search.submit", metadata: [
            "query": vm.query,
        ]) {
            history.push(vm.query)
            vm.submit()
            dismissSearch()
        }
    }
}
