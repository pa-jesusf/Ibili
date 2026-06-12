import SwiftUI
import UIKit

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

enum VideoCardOverflowAction {
    case copyBVID
    case watchLater
    case visitOwner
    case plainDislike
    case undoDislike
    case dislikeReason(FeedDislikeReasonDTO)
    case feedbackReason(FeedDislikeReasonDTO)
    case blockOwner
}

enum VideoCardOverflowMenuBuilder {
    static func configureButton(_ button: UIButton) {
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = UIColor.secondaryLabel
        button.transform = CGAffineTransform(rotationAngle: .pi / 2)
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = "更多操作"
    }

    static func makeMenu(
        bvid: String,
        author: String,
        ownerMID: Int64,
        dislikeReasons: [FeedDislikeReasonDTO],
        feedbackReasons: [FeedDislikeReasonDTO],
        actionHandler: @escaping (VideoCardOverflowAction) -> Void
    ) -> UIMenu {
        let trimmedBVID = bvid.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerName = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "UP 主"
            : author.trimmingCharacters(in: .whitespacesAndNewlines)
        var children: [UIMenuElement] = []

        if !trimmedBVID.isEmpty {
            children.append(UIAction(title: trimmedBVID, image: UIImage(systemName: "doc.on.doc")) { _ in
                actionHandler(.copyBVID)
            })
        } else {
            children.append(UIAction(title: "复制 BV 号", image: UIImage(systemName: "doc.on.doc")) { _ in
                actionHandler(.copyBVID)
            })
        }

        children.append(UIAction(title: "稍后再看", image: UIImage(systemName: "clock")) { _ in
            actionHandler(.watchLater)
        })

        children.append(UIAction(
            title: "访问：\(ownerName)",
            image: UIImage(systemName: "person.circle"),
            attributes: ownerMID <= 0 ? [.disabled] : []
        ) { _ in
            actionHandler(.visitOwner)
        })

        children.append(dislikeMenu(
            dislikeReasons: dislikeReasons,
            feedbackReasons: feedbackReasons,
            actionHandler: actionHandler
        ))

        children.append(UIAction(
            title: "拉黑：\(ownerName)",
            image: UIImage(systemName: "nosign"),
            attributes: ownerMID <= 0 ? [.disabled, .destructive] : [.destructive]
        ) { _ in
            actionHandler(.blockOwner)
        })

        return UIMenu(children: children)
    }

    private static func dislikeMenu(
        dislikeReasons: [FeedDislikeReasonDTO],
        feedbackReasons: [FeedDislikeReasonDTO],
        actionHandler: @escaping (VideoCardOverflowAction) -> Void
    ) -> UIMenu {
        var elements: [UIMenuElement] = []
        elements.append(contentsOf: dislikeReasons.map { reason in
            UIAction(title: reason.name, image: UIImage(systemName: "hand.thumbsdown")) { _ in
                actionHandler(.dislikeReason(reason))
            }
        })
        elements.append(contentsOf: feedbackReasons.map { reason in
            UIAction(title: reason.name, image: UIImage(systemName: "exclamationmark.bubble")) { _ in
                actionHandler(.feedbackReason(reason))
            }
        })

        if elements.isEmpty {
            elements.append(UIAction(title: "点踩", image: UIImage(systemName: "hand.thumbsdown")) { _ in
                actionHandler(.plainDislike)
            })
        }

        elements.append(UIAction(title: "撤销点踩", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
            actionHandler(.undoDislike)
        })

        return UIMenu(
            title: "不感兴趣",
            image: UIImage(systemName: "hand.thumbsdown"),
            children: elements
        )
    }
}
