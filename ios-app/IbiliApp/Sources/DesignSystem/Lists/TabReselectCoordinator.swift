import SwiftUI
import UIKit

@MainActor
final class TabReselectSignals: ObservableObject {
    @Published private(set) var home = 0
    @Published private(set) var dynamic = 0
    @Published private(set) var search = 0
    @Published private(set) var profile = 0

    func triggerHome() {
        home &+= 1
    }

    func triggerDynamic() {
        dynamic &+= 1
    }

    func triggerSearch() {
        search &+= 1
    }

    func triggerProfile() {
        profile &+= 1
    }
}

struct TabBarReselectObserver<Tab: Hashable>: UIViewControllerRepresentable {
    let selectedTab: Tab
    let orderedTabs: [Tab]
    let onSelect: (Tab) -> Void
    let onReselect: (Tab) -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.onResolve = { tabBarController, tabBar in
            context.coordinator.attach(to: tabBarController)
            context.coordinator.attach(to: tabBar)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverController, context: Context) {
        context.coordinator.selectedTab = selectedTab
        context.coordinator.orderedTabs = orderedTabs
        context.coordinator.onSelect = onSelect
        context.coordinator.onReselect = onReselect
        uiViewController.onResolve = { tabBarController, tabBar in
            context.coordinator.attach(to: tabBarController)
            context.coordinator.attach(to: tabBar)
        }
        uiViewController.resolve()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedTab: selectedTab,
            orderedTabs: orderedTabs,
            onSelect: onSelect,
            onReselect: onReselect
        )
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var selectedTab: Tab
        var orderedTabs: [Tab]
        var onSelect: (Tab) -> Void
        var onReselect: (Tab) -> Void
        private weak var tabBarController: UITabBarController?
        private weak var tabBar: UITabBar?
        private weak var tabBarTapRecognizer: UITapGestureRecognizer?
        private weak var previousDelegate: UITabBarControllerDelegate?

        init(selectedTab: Tab,
             orderedTabs: [Tab],
             onSelect: @escaping (Tab) -> Void,
             onReselect: @escaping (Tab) -> Void) {
            self.selectedTab = selectedTab
            self.orderedTabs = orderedTabs
            self.onSelect = onSelect
            self.onReselect = onReselect
        }

        func attach(to tabBarController: UITabBarController?) {
            guard let tabBarController else { return }
            if self.tabBarController === tabBarController {
                syncSelectionFromUIKit(reason: "controller-resolve", allowsReselect: false)
                return
            }
            previousDelegate = tabBarController.delegate
            self.tabBarController = tabBarController
            tabBarController.delegate = self
            attach(to: tabBarController.tabBar)
            syncSelectionFromUIKit(reason: "controller-attach", allowsReselect: false)
        }

        func attach(to tabBar: UITabBar?) {
            guard let tabBar else { return }
            if self.tabBar === tabBar {
                syncSelectionFromUIKit(reason: "tabbar-resolve", allowsReselect: false)
                return
            }
            if let tabBarTapRecognizer, let oldTabBar = self.tabBar {
                oldTabBar.removeGestureRecognizer(tabBarTapRecognizer)
            }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTabBarTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            tabBar.addGestureRecognizer(recognizer)
            self.tabBar = tabBar
            tabBarTapRecognizer = recognizer
            syncSelectionFromUIKit(reason: "tabbar-attach", allowsReselect: false)
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            let index = tabBarController.viewControllers?.firstIndex(of: viewController) ?? tabBarController.selectedIndex
            applySelection(index: index, reason: "delegate", allowsReselect: true, viewController: viewController)
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }

        @objc
        private func handleTabBarTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            DispatchQueue.main.async { [weak self] in
                self?.syncSelectionFromUIKit(reason: "tap-gesture", allowsReselect: true)
            }
        }

        private func syncSelectionFromUIKit(reason: String, allowsReselect: Bool) {
            if let tabBarController {
                applySelection(index: tabBarController.selectedIndex, reason: reason, allowsReselect: allowsReselect)
                return
            }
            guard let tabBar,
                  let selectedItem = tabBar.selectedItem,
                  let index = tabBar.items?.firstIndex(of: selectedItem) else { return }
            applySelection(index: index, reason: reason, allowsReselect: allowsReselect)
        }

        private func applySelection(index: Int,
                                    reason: String,
                                    allowsReselect: Bool,
                                    viewController: UIViewController? = nil) {
            guard orderedTabs.indices.contains(index) else { return }
            let tapped = orderedTabs[index]
            NavigationTrace.log("UITabBar selection sync", metadata: [
                "index": String(index),
                "reason": reason,
                "tab": "\(tapped)",
                "selectedBeforeSync": "\(selectedTab)",
                "viewController": viewController.map { String(describing: type(of: $0)) } ?? "nil",
            ], includeStack: reason == "delegate" || reason == "tap-gesture")
            if tapped == selectedTab {
                if allowsReselect {
                    onReselect(tapped)
                }
            } else {
                onSelect(tapped)
            }
        }
    }

    final class ObserverController: UIViewController {
        var onResolve: ((UITabBarController?, UITabBar?) -> Void)?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            resolve()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onResolve?(self.findTabBarController(), self.findTabBar())
            }
        }

        private func findTabBarController() -> UITabBarController? {
            var current: UIViewController? = self
            while let node = current {
                if let tab = node as? UITabBarController {
                    return tab
                }
                current = node.parent
            }
            return view.window?.rootViewController?.findDescendantTabBarController()
        }

        private func findTabBar() -> UITabBar? {
            if let tabBar = findTabBarController()?.tabBar {
                return tabBar
            }
            return view.window?.rootViewController?.view.findDescendantTabBar()
        }
    }
}

private extension UIViewController {
    func findDescendantTabBarController() -> UITabBarController? {
        if let tab = self as? UITabBarController {
            return tab
        }
        for child in children {
            if let found = child.findDescendantTabBarController() {
                return found
            }
        }
        if let presentedViewController,
           let found = presentedViewController.findDescendantTabBarController() {
            return found
        }
        return nil
    }
}

private extension UIView {
    func findDescendantTabBar() -> UITabBar? {
        if let tabBar = self as? UITabBar {
            return tabBar
        }
        for subview in subviews {
            if let found = subview.findDescendantTabBar() {
                return found
            }
        }
        return nil
    }
}
