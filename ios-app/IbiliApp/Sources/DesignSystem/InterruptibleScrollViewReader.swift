import SwiftUI
import UIKit

/// Bridges SwiftUI `ScrollViewReader` actions with the underlying
/// `UIScrollView` so programmatic jumps can interrupt deceleration.
final class InterruptibleScrollContext: ObservableObject {
    fileprivate weak var scrollView: UIScrollView? {
        didSet {
            if oldValue !== scrollView {
                observeContentOffset()
            }
            applyUserScrollingConfiguration()
        }
    }
    @Published private(set) var isPastVerticalOffsetThreshold = false
    private var userScrollingEnabled: Bool?
    private var alwaysBounceVertical = false
    private var verticalOffsetShowThreshold: CGFloat?
    private var verticalOffsetResetThreshold: CGFloat = 0
    private var contentOffsetObservation: NSKeyValueObservation?

    func interruptInFlightScroll() {
        guard let scrollView else { return }
        let offset = scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: false)
        scrollView.layer.removeAllAnimations()
    }

    func configureUserScrolling(enabled: Bool, alwaysBounceVertical: Bool) {
        userScrollingEnabled = enabled
        self.alwaysBounceVertical = alwaysBounceVertical
        applyUserScrollingConfiguration()
    }

    func configureVerticalOffsetThreshold(showAfter: CGFloat?, resetBelow: CGFloat = 0) {
        let configurationChanged = verticalOffsetShowThreshold != showAfter
            || verticalOffsetResetThreshold != resetBelow
        verticalOffsetShowThreshold = showAfter
        verticalOffsetResetThreshold = resetBelow
        if showAfter == nil {
            isPastVerticalOffsetThreshold = false
        }
        if configurationChanged {
            observeContentOffset()
        } else if let scrollView {
            updateVerticalOffsetState(for: scrollView)
        }
    }

    private func applyUserScrollingConfiguration() {
        guard let scrollView, let userScrollingEnabled else { return }
        scrollView.isScrollEnabled = userScrollingEnabled
        scrollView.alwaysBounceVertical = alwaysBounceVertical
    }

    private func observeContentOffset() {
        contentOffsetObservation?.invalidate()
        contentOffsetObservation = nil
        guard let scrollView, verticalOffsetShowThreshold != nil else { return }
        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scrollView, _ in
            self?.updateVerticalOffsetState(for: scrollView)
        }
    }

    private func updateVerticalOffsetState(for scrollView: UIScrollView) {
        guard let showThreshold = verticalOffsetShowThreshold else { return }
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        if isPastVerticalOffsetThreshold {
            if offset <= verticalOffsetResetThreshold {
                isPastVerticalOffsetThreshold = false
            }
        } else if offset >= showThreshold {
            isPastVerticalOffsetThreshold = true
        }
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
