import SwiftUI

struct CommentSurface<Item: Identifiable, Row: View>: View {
    let title: String
    let subtitle: String?
    let items: [Item]
    var isLoading: Bool = false
    var errorText: String? = nil
    var emptyMessage: String = "暂无评论"
    var onRefresh: (() -> Void)?
    let row: (Item) -> Row

    init(
        title: String = "评论",
        subtitle: String? = nil,
        items: [Item],
        isLoading: Bool = false,
        errorText: String? = nil,
        emptyMessage: String = "暂无评论",
        onRefresh: (() -> Void)? = nil,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.isLoading = isLoading
        self.errorText = errorText
        self.emptyMessage = emptyMessage
        self.onRefresh = onRefresh
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            Spacer()
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(IbiliTheme.accent)
                .disabled(isLoading)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, items.isEmpty {
            StateView(state: .loading())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else if let errorText, items.isEmpty {
            StateView(state: .error(title: "评论加载失败", systemImage: "bubble.left.and.bubble.right", message: errorText))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else if items.isEmpty {
            StateView(state: .empty(title: "暂无评论", systemImage: "bubble.left.and.bubble.right", message: emptyMessage))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }
}
