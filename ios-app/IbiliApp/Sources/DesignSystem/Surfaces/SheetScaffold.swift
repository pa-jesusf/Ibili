import SwiftUI

/// Common navigation shell for modal sheets.
///
/// Many sheets in the app need the same NavigationStack + tint + optional
/// done button. Keeping that chrome here prevents small visual differences
/// from creeping into settings, source management, and picker sheets.
struct SheetScaffold<Content: View>: View {
    let title: String
    var showsDoneButton: Bool = true
    var doneTitle: String = "完成"
    var leadingCancelTitle: String?
    let content: Content

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        showsDoneButton: Bool = true,
        doneTitle: String = "完成",
        leadingCancelTitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsDoneButton = showsDoneButton
        self.doneTitle = doneTitle
        self.leadingCancelTitle = leadingCancelTitle
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let leadingCancelTitle {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(leadingCancelTitle) { dismiss() }
                        }
                    }
                    if showsDoneButton {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(doneTitle) { dismiss() }
                        }
                    }
                }
        }
        .tint(IbiliTheme.accent)
    }
}
