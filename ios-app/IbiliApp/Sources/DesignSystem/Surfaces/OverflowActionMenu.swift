import SwiftUI

struct OverflowAction: Identifiable, Hashable {
    enum Role: Hashable {
        case normal
        case destructive
    }

    let id: String
    let title: String
    let systemImage: String
    var role: Role = .normal
    var children: [OverflowAction] = []

    init(
        id: String,
        title: String,
        systemImage: String,
        role: Role = .normal,
        children: [OverflowAction] = []
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.children = children
    }
}

struct OverflowActionMenu<LabelContent: View>: View {
    let actions: [OverflowAction]
    let onSelect: (OverflowAction) -> Void
    let label: LabelContent

    init(
        actions: [OverflowAction],
        onSelect: @escaping (OverflowAction) -> Void,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.actions = actions
        self.onSelect = onSelect
        self.label = label()
    }

    var body: some View {
        Menu {
            ForEach(actions) { action in
                if action.children.isEmpty {
                    menuButton(action)
                } else {
                    Menu {
                        ForEach(action.children) { child in
                            menuButton(child)
                        }
                    } label: {
                        SwiftUI.Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
        } label: {
            label
        }
    }

    @ViewBuilder
    private func menuButton(_ action: OverflowAction) -> some View {
        Button(role: action.role == .destructive ? .destructive : nil) {
            onSelect(action)
        } label: {
            SwiftUI.Label(action.title, systemImage: action.systemImage)
        }
    }
}
