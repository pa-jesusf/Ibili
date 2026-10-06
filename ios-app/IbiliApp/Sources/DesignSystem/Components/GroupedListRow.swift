import SwiftUI
import UIKit

extension View {
    /// Round the outer edges of the whole list, including a single-row list.
    func groupedListRow(isFirst: Bool, isLast: Bool) -> some View {
        clipShape(GroupedListRowShape(isFirst: isFirst, isLast: isLast))
    }
}

private struct GroupedListRowShape: Shape {
    let isFirst: Bool
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var corners: UIRectCorner = []
        if isFirst { corners.formUnion([.topLeft, .topRight]) }
        if isLast { corners.formUnion([.bottomLeft, .bottomRight]) }
        guard !corners.isEmpty else { return Path(rect) }
        let radius = min(16, min(rect.width, rect.height) / 2)
        return Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
