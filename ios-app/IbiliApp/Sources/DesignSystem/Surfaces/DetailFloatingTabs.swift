import SwiftUI
import UIKit

private enum DetailFloatingTabsMetrics {
    static let systemTabBarHeight: CGFloat = 50
}

/// Unified floating tab bar for detail-like surfaces:
/// video detail, aggregate anime player, and aggregate anime subject.
///
/// It keeps the reselect callback in the component so every page gets the
/// same "tap current tab to scroll back" behaviour instead of implementing
/// that gesture ad hoc.
struct DetailFloatingTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    let systemImage: (Tab) -> String?
    @Binding var selection: Tab
    let bottomSafeAreaInset: CGFloat
    var maxWidth: CGFloat? = nil
    var onReselectCurrentTab: () -> Void = {}
    @State private var hasAppeared = false

    var body: some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.94, anchor: .bottom)
            .offset(y: hasAppeared ? 0 : 22)
            .onAppear {
                guard !hasAppeared else { return }
                withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88, blendDuration: 0)) {
                    hasAppeared = true
                }
            }
            .onDisappear {
                hasAppeared = false
            }
    }

    @ViewBuilder
    private var content: some View {
        if #available(iOS 26.0, *) {
            DetailSystemTabBar(
                tabs: tabs,
                title: title,
                systemImage: systemImage,
                selection: $selection,
                onReselectCurrentTab: onReselectCurrentTab
            )
            .frame(maxWidth: maxWidth ?? .infinity)
            .frame(
                height: DetailFloatingTabsMetrics.systemTabBarHeight
                    + max(0, bottomSafeAreaInset)
            )
        } else {
            DetailPillTabs(
                tabs: tabs,
                title: title,
                selection: $selection,
                maxWidth: maxWidth,
                onReselectCurrentTab: onReselectCurrentTab
            )
            .padding(.horizontal, 16)
            .padding(.bottom, max(10, bottomSafeAreaInset))
        }
    }
}

@available(iOS 26.0, *)
private struct DetailSystemTabBar<Tab: Hashable & Identifiable>: UIViewRepresentable {
    let tabs: [Tab]
    let title: (Tab) -> String
    let systemImage: (Tab) -> String?
    @Binding var selection: Tab
    let onReselectCurrentTab: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onReselectCurrentTab: onReselectCurrentTab)
    }

    func makeUIView(context: Context) -> UITabBar {
        let tabBar = UITabBar(frame: .zero)
        tabBar.delegate = context.coordinator
        tabBar.tintColor = IbiliTheme.accentUIColor
        tabBar.unselectedItemTintColor = .secondaryLabel
        tabBar.itemPositioning = .automatic
        updateItems(on: tabBar, coordinator: context.coordinator)
        return tabBar
    }

    func updateUIView(_ uiView: UITabBar, context: Context) {
        updateItems(on: uiView, coordinator: context.coordinator)
    }

    private func updateItems(on tabBar: UITabBar, coordinator: Coordinator) {
        let resolvedItems = nativeItems
        coordinator.items = resolvedItems
        tabBar.tintColor = IbiliTheme.accentUIColor
        tabBar.unselectedItemTintColor = .secondaryLabel
        tabBar.setItems(resolvedItems.map(\.tabBarItem), animated: false)
        if let selectedItem = resolvedItems.first(where: { $0.tab == selection }) {
            tabBar.selectedItem = selectedItem.tabBarItem
        }
    }

    private var nativeItems: [NativeItem] {
        tabs.map { tab in
            NativeItem(
                tab: tab,
                tabBarItem: UITabBarItem(
                    title: title(tab),
                    image: systemImage(tab).flatMap(UIImage.init(systemName:)),
                    tag: tab.hashValue
                )
            )
        }
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var selection: Binding<Tab>
        var onReselectCurrentTab: () -> Void
        var items: [NativeItem] = []

        init(selection: Binding<Tab>, onReselectCurrentTab: @escaping () -> Void) {
            self.selection = selection
            self.onReselectCurrentTab = onReselectCurrentTab
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard let matchedItem = items.first(where: { $0.tabBarItem === item }) else { return }
            if selection.wrappedValue == matchedItem.tab {
                onReselectCurrentTab()
            } else {
                selection.wrappedValue = matchedItem.tab
            }
        }
    }

    struct NativeItem {
        let tab: Tab
        let tabBarItem: UITabBarItem
    }
}

private struct DetailPillTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab
    let maxWidth: CGFloat?
    let onReselectCurrentTab: () -> Void

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                let isSelected = selection == tab
                Button {
                    if isSelected {
                        onReselectCurrentTab()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selection = tab
                        }
                    }
                } label: {
                    Text(title(tab))
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? IbiliTheme.accent : IbiliTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(IbiliTheme.accent.opacity(0.16))
                                    .matchedGeometryEffect(id: "detail.floating.tab", in: indicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: maxWidth)
        .background(DetailFloatingTabsBackground())
    }
}

private struct DetailFloatingTabsBackground: View {
    var body: some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 8)
    }
}
