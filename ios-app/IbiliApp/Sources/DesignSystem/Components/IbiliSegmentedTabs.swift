import SwiftUI

/// Project-wide pill-style segmented control. The selected segment
/// floats inside a tinted accent capsule and renders its label in
/// `IbiliTheme.accent` (the brand pink); unselected segments are
/// plain secondary-weight text.
///
/// Used by:
///   • `VideoDetailContent` — 简介 / 评论 / 相关
///   • `UserSpaceView`     — 动态 / 投稿
///
/// Both surfaces previously had their own divergent looks (a stock
/// `Picker(.segmented)` on one side, a white-on-pink pill on the
/// other). Unifying them under a single component keeps the visual
/// language consistent and gives us one place to retune the
/// "Apple-aesthetic + brand pink" balance.
struct IbiliSegmentedTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let isSelected = (tab == selection)
                Button {
                    if !isSelected {
                        // 0.28s spring matches Apple's tab-switch
                        // cadence — fast enough to feel responsive,
                        // slow enough that the indicator's slide is
                        // legible at 120Hz.
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selection = tab
                        }
                    }
                } label: {
                    Text(title(tab))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                        .background {
                            if isSelected {
                                // Soft accent fill — same pink, much
                                // lower opacity, so the pill is felt
                                // rather than shouted.
                                Capsule()
                                    .fill(IbiliTheme.accent.opacity(0.16))
                                    .matchedGeometryEffect(id: "ibili.segmented.pill", in: pill)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            // Outer container: thin glass on iOS 26+, regularMaterial
            // pre-26. Mirrors `GlassCapsuleModifier` so the surface
            // language is identical across pages without having to
            // import that file (it's intentionally fileprivate).
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
            } else {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}
