import SwiftUI

/// Tag chip cloud rendered with `IbiliPill` + the existing `FlowLayout`.
struct VideoTagsView: View {
    let tags: [String]
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.inlinePlayerNavigation) private var inlinePlayerNavigation

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
        if isInPlayerHostNavigation, let inlinePlayerNavigation {
            inlinePlayerNavigation.openSearch(keyword: keyword)
        } else {
            router.openSearch(keyword: keyword)
        }
    }
}
