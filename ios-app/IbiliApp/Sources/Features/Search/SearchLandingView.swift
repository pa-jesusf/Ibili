import SwiftUI

/// Default content of the Search screen when no query is active:
/// shows the user's recent search history (if any) plus the static
/// `分区` grid. Tapping any item triggers a fresh search through the
/// shared view model.
struct SearchLandingView: View {
    @ObservedObject var vm: SearchViewModel
    @ObservedObject var history: SearchHistoryStore
    /// Hook injected by `SearchView` so taps on a chip can dismiss
    /// the system search field while submitting.
    var onSubmit: (String, SearchCategory?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !history.entries.isEmpty {
                    historySection
                }
                categoriesSection
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(IbiliTheme.background)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IbiliSectionHeader(title: "搜索历史", systemImage: "clock") {
                Button("清空") { history.clear() }
                    .font(.subheadline)
                    .foregroundStyle(IbiliTheme.accent)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(history.entries, id: \.self) { entry in
                    Button {
                        onSubmit(entry, nil)
                    } label: {
                        IbiliPill(title: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            history.remove(entry)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IbiliSectionHeader(title: "分区", systemImage: "square.grid.2x2.fill")
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10, alignment: .leading),
                    count: 2
                ),
                spacing: 10
            ) {
                ForEach(SearchCategories.all) { cat in
                    Button {
                        onSubmit(cat.name, cat)
                    } label: {
                        categoryCell(cat)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func categoryCell(_ cat: SearchCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cat.systemImage)
                .imageScale(.medium)
                .foregroundStyle(IbiliTheme.accent)
                .frame(width: 22)
            Text(cat.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(IbiliTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}
