import SwiftUI

/// Section header with an optional leading SF Symbol icon and an
/// optional trailing affordance (e.g. a "清空" button). Used by the
/// search landing screen for `搜索历史` and `分区`.
struct IbiliSectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    var iconColor: Color = IbiliTheme.textSecondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                    .imageScale(.medium)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(IbiliTheme.textPrimary)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension IbiliSectionHeader where Trailing == EmptyView {
    init(
        title: String,
        systemImage: String? = nil,
        iconColor: Color = IbiliTheme.textSecondary
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            iconColor: iconColor
        ) { EmptyView() }
    }
}
