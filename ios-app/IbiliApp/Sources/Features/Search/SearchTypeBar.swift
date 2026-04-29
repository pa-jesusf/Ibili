import SwiftUI

/// Horizontal scrolling row of result-type filter chips, e.g.
/// `视频 / 番剧 / 影视 / 用户 / 直播 / 专栏`. Bound to
/// `SearchViewModel.selectedType`.
struct SearchTypeBar: View {
    @ObservedObject var vm: SearchViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchResultType.allCases) { type in
                    Button {
                        vm.selectedType = type
                    } label: {
                        IbiliPill(
                            title: type.label,
                            style: vm.selectedType == type ? .selected : .neutral,
                            horizontalPadding: 12,
                            verticalPadding: 6
                        )
                        .opacity(type.isImplemented ? 1.0 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .disabled(!type.isImplemented)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
