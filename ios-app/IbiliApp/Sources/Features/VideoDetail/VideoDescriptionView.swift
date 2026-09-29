import SwiftUI

/// Preserve descV2's server-resolved mentions; other links and timestamps
/// use the same renderer as comments.
struct VideoDescriptionView: View {
    let desc: String
    let descV2: [VideoDescNodeDTO]

    var body: some View {
        ExpandableText(text: rendered, lineLimit: 3, font: .footnote,
                       jumpUrls: mentions, detectsLinks: true)
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
            case 2: return node.rawText.hasPrefix("@") ? node.rawText : "@\(node.rawText)"
            default: return node.rawText
            }
        }.joined()
    }

    private var mentions: [ReplyJumpUrlDTO] {
        descV2.filter { $0.kind == 2 && $0.bizId > 0 && !$0.rawText.isEmpty }.map {
            let label = $0.rawText.hasPrefix("@") ? $0.rawText : "@\($0.rawText)"
            return ReplyJumpUrlDTO(keyword: label, title: label, url: "ibili://space/\($0.bizId)", prefixIcon: "")
        }
    }
}
