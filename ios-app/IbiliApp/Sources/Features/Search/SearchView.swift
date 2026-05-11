import SwiftUI

/// Top-level search screen. Owns the `NavigationStack`, the inline search
/// field, and switches between the landing view (history + 分区) and the
/// result grid.
struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @StateObject private var history = SearchHistoryStore()
    @State private var isFiltersSheetPresented: Bool = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchInlineInputBar(
                    text: $vm.query,
                    isFocused: $isSearchFocused,
                    onSubmit: submitCurrentQuery
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)

                content
            }
                .background(IbiliTheme.background)
                .navigationTitle("搜索")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
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
        history.push(vm.query)
        vm.submit()
        isSearchFocused = false
    }
}

private struct SearchInlineInputBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IbiliTheme.textSecondary)

            TextField("搜索视频、UP主、番剧", text: $text)
                .focused(isFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(IbiliTheme.textPrimary)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textSecondary.opacity(0.72))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(IbiliTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}
