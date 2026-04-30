import SwiftUI
import UIKit

/// Presents a modal sheet containing a fully selectable, scrollable
/// text view so the user can highlight an arbitrary substring and
/// copy it via the standard iOS edit menu.
///
/// Used by the video detail page's title / description / comment
/// long-press "选择复制" affordances.
enum SelectableTextPresenter {
    static func present(text: String, title: String) {
        guard let root = topMostController() else { return }
        let host = UIHostingController(rootView: SelectableTextSheet(text: text, title: title))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        root.present(host, animated: true)
    }

    private static func topMostController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

private struct SelectableTextSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                        dismiss()
                    } label: { Label("复制全部", systemImage: "doc.on.doc") }
                }
            }
        }
    }
}
