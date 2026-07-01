import SwiftUI

/// Tag chip cloud rendered with `IbiliPill` + the existing `FlowLayout`.
struct VideoTagsView: View {
    let tags: [String]
    @Environment(\.rootContentNavigation) private var rootNavigation

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    openSearch(keyword: tag)
                } label: {
                    IbiliPill(title: tag, horizontalPadding: 10, verticalPadding: 5)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = tag
                    } label: {
                        Label("复制标签", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    private func openSearch(keyword: String) {
        rootNavigation.openSearch(keyword: keyword)
    }
}
