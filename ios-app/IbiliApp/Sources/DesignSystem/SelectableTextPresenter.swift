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
            SelectableTextView(text: text)
                .padding(.horizontal, 12)
                .padding(.top, 8)
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

/// `UITextView` wrapper — the SwiftUI `Text(...).textSelection(.enabled)`
/// path silently breaks long-press selection inside a sheet on iOS 16/17,
/// so we drop down to UIKit which honours the standard edit menu.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = true
        v.backgroundColor = .clear
        v.textContainer.lineFragmentPadding = 0
        v.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.dataDetectorTypes = [.link]
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}
