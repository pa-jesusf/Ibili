import SwiftUI

struct VideoCardOverflowMenu: View {
    let bvid: String
    let author: String
    let ownerMID: Int64
    let dislikeReasons: [FeedDislikeReasonDTO]
    let feedbackReasons: [FeedDislikeReasonDTO]
    var onCopyBVID: () -> Void
    var onWatchLater: () -> Void
    var onVisitOwner: () -> Void
    var onPlainDislike: () -> Void
    var onUndoDislike: () -> Void
    var onDislikeReason: (FeedDislikeReasonDTO) -> Void
    var onFeedbackReason: (FeedDislikeReasonDTO) -> Void
    var onBlockOwner: () -> Void

    var body: some View {
        Menu {
            if !bvid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: onCopyBVID) {
                    Label(bvid, systemImage: "doc.on.doc")
                }
            }

            Button(action: onWatchLater) {
                Label("稍后再看", systemImage: "clock")
            }

            Button(action: onVisitOwner) {
                Label("访问：\(ownerName)", systemImage: "person.circle")
            }
            .disabled(ownerMID <= 0)

            if hasFeedReasons {
                Menu {
                    ForEach(reasonChoices) { choice in
                        Button(choice.reason.name) {
                            switch choice.kind {
                            case .dislike:
                                onDislikeReason(choice.reason)
                            case .feedback:
                                onFeedbackReason(choice.reason)
                            }
                        }
                    }
                    Divider()
                    Button(action: onUndoDislike) {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                } label: {
                    Label("不感兴趣", systemImage: "hand.thumbsdown")
                }
            } else {
                Menu {
                    Button(action: onPlainDislike) {
                        Label("点踩", systemImage: "hand.thumbsdown")
                    }
                    Button(action: onUndoDislike) {
                        Label("撤销点踩", systemImage: "arrow.uturn.backward")
                    }
                } label: {
                    Label("不感兴趣", systemImage: "hand.thumbsdown")
                }
            }

            Button(role: .destructive, action: onBlockOwner) {
                Label("拉黑：\(ownerName)", systemImage: "nosign")
            }
            .disabled(ownerMID <= 0)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IbiliTheme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多操作")
    }

    private var ownerName: String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "UP 主" : trimmed
    }

    private var hasFeedReasons: Bool {
        !dislikeReasons.isEmpty || !feedbackReasons.isEmpty
    }

    private var reasonChoices: [VideoDislikeReasonChoice] {
        dislikeReasons.map { .init(kind: .dislike, reason: $0) }
            + feedbackReasons.map { .init(kind: .feedback, reason: $0) }
    }
}

private struct VideoDislikeReasonChoice: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case dislike
        case feedback
    }

    let kind: Kind
    let reason: FeedDislikeReasonDTO

    var id: String {
        "\(kind.rawValue):\(reason.id):\(reason.name)"
    }
}
