import SwiftUI

/// Description (`desc` / `descV2`) wrapped in `ExpandableText`. We
/// flatten `descV2` to plain text — the at-user navigation is a future
/// nice-to-have; for now we render the @-mention with a subtle accent
/// so the user can see the reference but cannot drill in.
struct VideoDescriptionView: View {
    let desc: String
    let descV2: [VideoDescNodeDTO]

    var body: some View {
        ExpandableText(text: rendered, lineLimit: 3, font: .footnote)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = rendered
                } label: { Label("复制全部", systemImage: "doc.on.doc") }
                Button {
                    SelectableTextPresenter.present(text: rendered, title: "选择复制简介")
                } label: { Label("选择复制", systemImage: "selection.pin.in.out") }
            }
    }

    private var rendered: String {
        if descV2.isEmpty { return desc.trimmingCharacters(in: .whitespacesAndNewlines) }
        return descV2.map { node in
            switch node.kind {
            case 2: return "@\(node.rawText)"
            default: return node.rawText
            }
        }.joined()
    }
}
