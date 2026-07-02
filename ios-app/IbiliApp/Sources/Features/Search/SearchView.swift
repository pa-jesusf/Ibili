import SwiftUI

/// Top-level search screen. The root content host owns the `NavigationStack`;
/// this view owns the system search field only on legacy tabs.
struct SearchView: View {
    @ObservedObject var vm: SearchViewModel
    @ObservedObject var history: SearchHistoryStore
    @Binding var isFiltersSheetPresented: Bool
    let hostsSearchField: Bool
    let onProgrammaticSubmit: () -> Void
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.rootContentNavigation) private var rootContentNavigation

    init(vm: SearchViewModel,
         history: SearchHistoryStore,
         isFiltersSheetPresented: Binding<Bool>,
         hostsSearchField: Bool = true,
         onProgrammaticSubmit: @escaping () -> Void = {}) {
        self.vm = vm
        self.history = history
        _isFiltersSheetPresented = isFiltersSheetPresented
        self.hostsSearchField = hostsSearchField
        self.onProgrammaticSubmit = onProgrammaticSubmit
    }

    @ViewBuilder
    var body: some View {
        baseContent
    }

    private var baseContent: some View {
        searchFieldHostIfNeeded(navigationContent)
            .environment(\.openURL, OpenURLAction { url in
                rootContentNavigation.handle(url, router: router)
            })
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .tint(IbiliTheme.accent)
            .sheet(isPresented: $isFiltersSheetPresented) {
                SearchFiltersSheet(vm: vm)
            }
    }

    @ViewBuilder
    private func searchFieldHostIfNeeded<Content: View>(_ content: Content) -> some View {
        if hostsSearchField {
            content
                .searchable(text: $vm.query, prompt: "搜索视频、UP主、番剧")
                .onSubmit(of: .search, submitCurrentQuery)
        } else {
            content
        }
    }

    private var navigationContent: some View {
        content
            .background(IbiliTheme.background)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationTracePage("SearchRoot", metadata: [
                "transitionWorld": "root-content-child",
            ])
            .background(SearchPresentationTrace())
    }

    @ViewBuilder
    private var content: some View {
        if vm.hasActiveSubmittedQuery {
            VStack(spacing: 0) {
                SearchTypeBar(vm: vm)
                Divider().opacity(0.4)
                SearchResultsView(vm: vm)
            }
        } else {
            SearchLandingView(vm: vm, history: history) { query, category in
                vm.submit(query: query, category: category)
                history.push(query)
                dismissSearch()
                onProgrammaticSubmit()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if vm.hasActiveSubmittedQuery, vm.selectedType.hasFilters {
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
            onProgrammaticSubmit()
        }
    }
}

private struct SearchPresentationTrace: View {
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                NavigationTrace.log("搜索控件状态", metadata: [
                    "isSearching": String(isSearching),
                    "event": "appear",
                ])
            }
            .onChange(of: isSearching) { value in
                NavigationTrace.log("搜索控件状态", metadata: [
                    "isSearching": String(value),
                    "event": "change",
                ])
            }
    }
}
