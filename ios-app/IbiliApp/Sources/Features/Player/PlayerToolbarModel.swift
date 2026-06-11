import SwiftUI

struct PlayerToolbarAction: Identifiable, Hashable {
    enum Kind: Hashable {
        case toggle
        case button
        case menu
    }

    let id: String
    let title: String
    let systemImage: String
    let kind: Kind
    var isEnabled: Bool = true
    var isSelected: Bool = false
    var children: [PlayerToolbarAction] = []
}

struct PlayerToolbarModel: Hashable {
    var leading: [PlayerToolbarAction] = []
    var trailing: [PlayerToolbarAction] = []
    var overflow: [PlayerToolbarAction] = []
}
