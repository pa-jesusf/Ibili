import SwiftUI
import UIKit

/// Top-level search screen. The root content host owns the `NavigationStack`;
/// this view owns the system search field only on legacy tabs.
struct SearchView: View {
    @ObservedObject var vm: SearchViewModel
    @ObservedObject var history: SearchHistoryStore
    @Binding var isFiltersSheetPresented: Bool
    let hostsSearchField: Bool
    let onSearchSubmitted: () -> Void
    let onReturnToLanding: () -> Void
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.rootContentNavigation) private var rootContentNavigation

    init(vm: SearchViewModel,
         history: SearchHistoryStore,
         isFiltersSheetPresented: Binding<Bool>,
         hostsSearchField: Bool = true,
         onSearchSubmitted: @escaping () -> Void = {},
         onReturnToLanding: @escaping () -> Void = {}) {
        self.vm = vm
        self.history = history
        _isFiltersSheetPresented = isFiltersSheetPresented
        self.hostsSearchField = hostsSearchField
        self.onSearchSubmitted = onSearchSubmitted
        self.onReturnToLanding = onReturnToLanding
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
                .onChange(of: vm.query) { newValue in
                    vm.handleQueryTextChanged(newValue)
                }
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
    }

    @ViewBuilder
    private var content: some View {
        if showsResultsContent {
            VStack(spacing: 0) {
                SearchTypeBar(vm: vm)
                Divider().opacity(0.4)
                SearchResultsView(vm: vm)
            }
        } else {
            SearchLandingView(vm: vm, history: history) { query, category in
                submit(query: query, category: category)
            }
        }
    }

    private var showsResultsContent: Bool {
        vm.hasActiveSubmittedQuery
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsResultsContent {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    vm.reset()
                    onReturnToLanding()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .foregroundStyle(IbiliTheme.textSecondary)
                .accessibilityLabel("清空搜索")

                if vm.selectedType.hasFilters {
                    Button {
                        isFiltersSheetPresented = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .foregroundStyle(IbiliTheme.accent)
                    .accessibilityLabel("筛选")
                }
            }
        }
    }

    private func submit(query: String, category: SearchCategory?) {
        NavigationTrace.withUserAction("search.submit", metadata: [
            "query": query,
            "category": category?.name ?? "nil",
        ]) {
            guard vm.submit(query: query, category: category) else { return }
            history.push(vm.submittedQuery)
            SearchKeyboard.dismiss()
            onSearchSubmitted()
        }
    }

    private func submitCurrentQuery() {
        NavigationTrace.withUserAction("search.submit", metadata: [
            "query": vm.query,
        ]) {
            guard vm.submit() else { return }
            history.push(vm.submittedQuery)
            SearchKeyboard.dismiss()
            onSearchSubmitted()
        }
    }
}

enum SearchKeyboard {
    static func dismiss() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .endEditing(true)
    }
}
