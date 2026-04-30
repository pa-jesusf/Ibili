import SwiftUI

/// Long-press affordance on the favorite button — lists every
/// favourite folder owned by the user and lets them flip multi-select
/// checkboxes, then commit. Mirrors the upstream PiliPlus "选择收藏夹"
/// bottom sheet.
struct FavoriteFolderPickerSheet: View {
    let aid: Int64
    @ObservedObject var interaction: VideoInteractionService
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int64> = []

    var body: some View {
        NavigationStack {
            Group {
                if interaction.folders.isEmpty {
                    emptyState(title: "暂无收藏夹", symbol: "star")
                } else {
                    List {
                        ForEach(interaction.folders) { folder in
                            Button {
                                toggle(folder.folderId)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.title)
                                            .foregroundStyle(IbiliTheme.textPrimary)
                                        Text("\(folder.mediaCount) 条")
                                            .font(.caption)
                                            .foregroundStyle(IbiliTheme.textSecondary)
                                    }
                                    Spacer()
                                    if selected.contains(folder.folderId) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(IbiliTheme.accent)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(IbiliTheme.textSecondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("选择收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        interaction.applyFavoriteSelection(aid: aid, selected: selected)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { selected = interaction.favoritedFolderIds }
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
