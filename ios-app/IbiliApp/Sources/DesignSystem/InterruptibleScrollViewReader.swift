import SwiftUI
import UIKit

/// Bridges SwiftUI `ScrollViewReader` actions with the underlying
/// `UIScrollView` so programmatic jumps can interrupt deceleration.
final class InterruptibleScrollContext: ObservableObject {
    fileprivate weak var scrollView: UIScrollView?

    func interruptInFlightScroll() {
        guard let scrollView else { return }
        let offset = scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: false)
        scrollView.layer.removeAllAnimations()
    }
}

struct InterruptibleScrollCapture: UIViewRepresentable {
    @ObservedObject var context: InterruptibleScrollContext

    func makeUIView(context: Context) -> ScrollCaptureView {
        let view = ScrollCaptureView()
        view.onResolve = { [weak scrollContext = self.context] scrollView in
            scrollContext?.scrollView = scrollView
        }
        return view
    }

    func updateUIView(_ uiView: ScrollCaptureView, context: Context) {
        uiView.onResolve = { [weak scrollContext = self.context] scrollView in
            scrollContext?.scrollView = scrollView
        }
        uiView.resolve()
    }

    final class ScrollCaptureView: UIView {
        var onResolve: ((UIScrollView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onResolve?(self.enclosingScrollView())
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

extension ScrollViewProxy {
    func interruptingScrollTo<ID: Hashable>(
        _ id: ID,
        anchor: UnitPoint? = nil,
        context: InterruptibleScrollContext,
        animation: Animation? = .easeOut(duration: 0.2)
    ) {
        context.interruptInFlightScroll()
        DispatchQueue.main.async {
            if let animation {
                withAnimation(animation) {
                    scrollTo(id, anchor: anchor)
                }
            } else {
                scrollTo(id, anchor: anchor)
            }
        }
    }
}
