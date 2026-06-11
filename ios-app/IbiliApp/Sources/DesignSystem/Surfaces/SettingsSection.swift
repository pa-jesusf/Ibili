import SwiftUI

struct SettingsSection<Content: View, Footer: View>: View {
    let title: String?
    let footer: Footer
    let content: Content

    init(
        _ title: String? = nil,
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            if let title {
                Text(title)
            }
        } footer: {
            footer
        }
    }
}

typealias FormSection = SettingsSection
