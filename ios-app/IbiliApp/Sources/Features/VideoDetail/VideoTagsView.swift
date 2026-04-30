import SwiftUI

/// Tag chip cloud rendered with `IbiliPill` + the existing `FlowLayout`.
struct VideoTagsView: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                IbiliPill(title: tag, horizontalPadding: 10, verticalPadding: 5)
            }
        }
    }
}
