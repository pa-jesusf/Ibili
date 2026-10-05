import SwiftUI

/// Search results screen used when a tag / rich reply keyword is opened
/// from an existing navigation stack. Unlike `SearchView`, this view does
/// not create another `NavigationStack`; it relies on the caller's stack.
struct SearchRouteView: View {
    let keyword: String

    @StateObject private var vm = SearchViewModel()
    @State private var isFiltersSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            SearchTypeBar(vm: vm, onShowFilters: { isFiltersSheetPresented = true })
            Divider().opacity(0.4)
            SearchResultsView(vm: vm)
        }
        .background(IbiliTheme.background)
        .navigationTitle(keyword)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: keyword) {
            vm.submit(query: keyword)
        }
        .sheet(isPresented: $isFiltersSheetPresented) {
            SearchFiltersSheet(vm: vm)
        }
        .tint(IbiliTheme.accent)
    }

}
