import SwiftUI

struct PersonGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var columns: Int = 2
    var spacing: CGFloat = 12
    let content: (Item) -> Content

    init(
        items: [Item],
        columns: Int = 2,
        spacing: CGFloat = 12,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.columns = max(1, columns)
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}
