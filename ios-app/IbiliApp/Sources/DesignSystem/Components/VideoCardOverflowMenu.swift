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

            Menu {
                if dislikeReasons.isEmpty && feedbackReasons.isEmpty {
                    Button(action: onPlainDislike) {
                        Label("点踩", systemImage: "hand.thumbsdown")
                    }
                    Button(action: onUndoDislike) {
                        Label("撤销点踩", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    if !dislikeReasons.isEmpty {
                        Section("我不想看") {
                            ForEach(dislikeReasons) { reason in
                                Button(action: { onDislikeReason(reason) }) {
                                    Text(reason.name)
                                }
                            }
                        }
                    }
                    if !feedbackReasons.isEmpty {
                        Section("反馈") {
                            ForEach(feedbackReasons) { reason in
                                Button(action: { onFeedbackReason(reason) }) {
                                    Text(reason.name)
                                }
                            }
                        }
                    }
                    Divider()
                    Button(action: onUndoDislike) {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Label("不感兴趣", systemImage: "hand.thumbsdown")
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
}
