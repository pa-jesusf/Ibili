import SwiftUI
import UIKit

/// Registers a rectangular region where the player host's window-level
/// swipe-back recognizer should stay out of the way. This is for controls
/// that legitimately need horizontal drags, such as episode carousels.
enum PlayerSwipeBackGestureExclusions {
    private static let lock = NSLock()
    private static let views = NSHashTable<UIView>.weakObjects()

    static func register(_ view: UIView) {
        lock.lock()
        views.add(view)
        lock.unlock()
    }

    static func unregister(_ view: UIView) {
        lock.lock()
        views.remove(view)
        lock.unlock()
    }

    static func contains(_ touch: UITouch, in container: UIView?) -> Bool {
        guard let window = container?.window else { return false }
        if isRegisteredOrDescendant(touch.view) {
            return true
        }
        return containsWindowPoint(touch.location(in: window), in: window)
    }

    static func contains(point: CGPoint, in container: UIView?) -> Bool {
        guard let container else { return false }
        let window = (container as? UIWindow) ?? container.window
        guard let window else { return false }
        return containsWindowPoint(container.convert(point, to: window), in: window)
    }

    static func isRegisteredOrDescendant(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if containsRegisteredView(candidate) {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    private static func containsRegisteredView(_ view: UIView) -> Bool {
        lock.lock()
        let result = views.contains(view)
        lock.unlock()
        return result
    }

    private static func containsWindowPoint(_ point: CGPoint, in window: UIWindow) -> Bool {
        lock.lock()
        let candidates = views.allObjects
        lock.unlock()
        for view in candidates where view.window === window && !view.isHidden && view.alpha > 0.01 {
            let rect = view.convert(view.bounds, to: window).insetBy(dx: -8, dy: -8)
            if rect.contains(point) {
                return true
            }
        }
        return false
    }
}

struct PlayerSwipeBackExclusionZone: UIViewRepresentable {
    var includeEnclosingScrollView = false

    func makeUIView(context: Context) -> ExclusionView {
        let view = ExclusionView()
        view.includeEnclosingScrollView = includeEnclosingScrollView
        return view
    }

    func updateUIView(_ uiView: ExclusionView, context: Context) {
        uiView.includeEnclosingScrollView = includeEnclosingScrollView
        uiView.registerIfNeeded()
        uiView.resolveEnclosingScrollViewIfNeeded()
    }

    static func dismantleUIView(_ uiView: ExclusionView, coordinator: ()) {
        uiView.unregister()
    }

    final class ExclusionView: UIView {
        private var isRegistered = false
        private weak var registeredScrollView: UIScrollView?
        var includeEnclosingScrollView = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        deinit {
            unregister()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                unregister()
            } else {
                registerIfNeeded()
                resolveEnclosingScrollViewIfNeeded()
            }
        }

        func registerIfNeeded() {
            guard window != nil, !isRegistered else { return }
            PlayerSwipeBackGestureExclusions.register(self)
            isRegistered = true
        }

        func unregister() {
            guard isRegistered else { return }
            PlayerSwipeBackGestureExclusions.unregister(self)
            if let registeredScrollView {
                PlayerSwipeBackGestureExclusions.unregister(registeredScrollView)
                self.registeredScrollView = nil
            }
            isRegistered = false
        }

        func resolveEnclosingScrollViewIfNeeded() {
            guard includeEnclosingScrollView else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                let scrollView = self.enclosingScrollView()
                guard self.registeredScrollView !== scrollView else { return }
                if let old = self.registeredScrollView {
                    PlayerSwipeBackGestureExclusions.unregister(old)
                }
                self.registeredScrollView = scrollView
                if let scrollView {
                    PlayerSwipeBackGestureExclusions.register(scrollView)
                }
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }
}
