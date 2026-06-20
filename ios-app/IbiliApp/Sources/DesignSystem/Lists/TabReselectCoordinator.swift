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
    let onReselect: (Tab) -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.onResolve = { tabBarController in
            guard let tabBarController else { return }
            context.coordinator.attach(to: tabBarController)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverController, context: Context) {
        context.coordinator.selectedTab = selectedTab
        context.coordinator.orderedTabs = orderedTabs
        context.coordinator.onReselect = onReselect
        uiViewController.onResolve = { tabBarController in
            guard let tabBarController else { return }
            context.coordinator.attach(to: tabBarController)
        }
        uiViewController.resolve()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedTab: selectedTab, orderedTabs: orderedTabs, onReselect: onReselect)
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var selectedTab: Tab
        var orderedTabs: [Tab]
        var onReselect: (Tab) -> Void
        private weak var tabBarController: UITabBarController?
        private weak var previousDelegate: UITabBarControllerDelegate?

        init(selectedTab: Tab, orderedTabs: [Tab], onReselect: @escaping (Tab) -> Void) {
            self.selectedTab = selectedTab
            self.orderedTabs = orderedTabs
            self.onReselect = onReselect
        }

        func attach(to tabBarController: UITabBarController) {
            guard self.tabBarController !== tabBarController else { return }
            previousDelegate = tabBarController.delegate
            self.tabBarController = tabBarController
            tabBarController.delegate = self
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            let index = tabBarController.viewControllers?.firstIndex(of: viewController) ?? tabBarController.selectedIndex
            if orderedTabs.indices.contains(index) {
                let tapped = orderedTabs[index]
                if tapped == selectedTab {
                    onReselect(tapped)
                }
            }
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }
    }

    final class ObserverController: UIViewController {
        var onResolve: ((UITabBarController?) -> Void)?

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
                self.onResolve?(self.findTabBarController())
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
