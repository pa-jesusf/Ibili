import SwiftUI
import UIKit

struct SplitFeedTransitionConfiguration: Equatable {
    let containerSize: CGSize
    let targetLeftWidth: CGFloat
    let fullColumns: Int
    let splitColumns: Int
}

enum SplitFeedTransitionDirection {
    case entering
    case exiting
}

struct SplitFeedCardSnapshot {
    let view: UIView
    let startFrame: CGRect
    let endFrame: CGRect
}

struct SplitFeedGridGeometry: Equatable {
    let columns: Int
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let horizontalInset: CGFloat
    let interitemSpacing: CGFloat
    let rowSpacing: CGFloat

    func frame(
        for index: Int,
        anchorIndex: Int,
        anchorScreenY: CGFloat,
        originX: CGFloat = 0,
        height: CGFloat? = nil
    ) -> CGRect {
        let resolvedColumns = max(1, columns)
        let row = index / resolvedColumns
        let column = index % resolvedColumns
        let anchorRow = anchorIndex / resolvedColumns
        return CGRect(
            x: originX + horizontalInset + CGFloat(column) * (itemWidth + interitemSpacing),
            y: anchorScreenY + CGFloat(row - anchorRow) * (itemHeight + rowSpacing),
            width: itemWidth,
            height: height ?? itemHeight
        )
    }

    static func topRightIndex(in frames: [(index: Int, frame: CGRect)]) -> Int? {
        guard let topY = frames.map(\.frame.minY).min() else { return nil }
        let minimumHeight = frames.map(\.frame.height).min() ?? 40
        let tolerance = max(8, minimumHeight * 0.2)
        return frames
            .filter { abs($0.frame.minY - topY) <= tolerance }
            .max(by: { $0.frame.maxX < $1.frame.maxX })?
            .index
    }

    static func contentOffsetY(
        anchorContentY: CGFloat,
        anchorScreenY: CGFloat,
        collectionScreenMinY: CGFloat,
        minimumY: CGFloat,
        maximumY: CGFloat
    ) -> CGFloat {
        let proposed = anchorContentY - (anchorScreenY - collectionScreenMinY)
        return min(max(proposed, minimumY), max(minimumY, maximumY))
    }
}

@MainActor
protocol SplitFeedTransitionSource: AnyObject {
    func makeSnapshots(
        direction: SplitFeedTransitionDirection,
        selectedID: FeedStableIdentity?,
        configuration: SplitFeedTransitionConfiguration
    ) -> [SplitFeedCardSnapshot]
    func setTransitionCardsHidden(_ hidden: Bool)
}

@MainActor
final class SplitFeedTransitionCoordinator: ObservableObject {
    private final class Registration {
        weak var source: (any SplitFeedTransitionSource)?
        var configuration: SplitFeedTransitionConfiguration

        init(source: any SplitFeedTransitionSource, configuration: SplitFeedTransitionConfiguration) {
            self.source = source
            self.configuration = configuration
        }
    }

    private var registrations: [Registration] = []
    private weak var activeSource: (any SplitFeedTransitionSource)?
    private var animator: UIViewPropertyAnimator?
    private weak var overlayView: UIView?

    private(set) var isAnimating = false

    func register(
        source: SplitFeedTransitionSource,
        configuration: SplitFeedTransitionConfiguration?
    ) {
        registrations.removeAll { $0.source == nil }
        guard let configuration else {
            unregister(source: source)
            return
        }
        if let registration = registrations.first(where: { $0.source === source }) {
            registration.configuration = configuration
        } else {
            registrations.append(Registration(source: source, configuration: configuration))
        }
    }

    func unregister(source: SplitFeedTransitionSource) {
        registrations.removeAll { $0.source == nil || $0.source === source }
        if activeSource === source, !isAnimating {
            activeSource = nil
        }
    }

    @discardableResult
    func prepareEntering(selectedID: FeedStableIdentity) -> Bool {
        start(direction: .entering, selectedID: selectedID)
    }

    @discardableResult
    func prepareExiting() -> Bool {
        start(direction: .exiting, selectedID: nil)
    }

    func cancel() {
        animator?.stopAnimation(true)
        animator = nil
        overlayView?.removeFromSuperview()
        activeSource?.setTransitionCardsHidden(false)
        registrations.compactMap(\.source).forEach { $0.setTransitionCardsHidden(false) }
        activeSource = nil
        isAnimating = false
    }

    private func start(
        direction: SplitFeedTransitionDirection,
        selectedID: FeedStableIdentity?
    ) -> Bool {
        guard !isAnimating, let window = foregroundWindow() else { return false }
        registrations.removeAll { $0.source == nil }

        let candidates: [Registration]
        switch direction {
        case .entering:
            candidates = registrations.reversed()
        case .exiting:
            candidates = registrations.filter { $0.source === activeSource }
        }

        var resolvedSource: (any SplitFeedTransitionSource)?
        var snapshots: [SplitFeedCardSnapshot] = []
        for registration in candidates {
            guard let source = registration.source else { continue }
            let candidateSnapshots = source.makeSnapshots(
                direction: direction,
                selectedID: selectedID,
                configuration: registration.configuration
            )
            guard !candidateSnapshots.isEmpty else { continue }
            resolvedSource = source
            snapshots = candidateSnapshots
            break
        }
        guard let source = resolvedSource else { return false }
        if direction == .entering {
            activeSource = source
        }

        let overlay = UIView(frame: window.bounds)
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        overlayView = overlay

        for snapshot in snapshots {
            snapshot.view.frame = snapshot.startFrame
            overlay.addSubview(snapshot.view)
        }
        source.setTransitionCardsHidden(true)
        isAnimating = true

        let animator = UIViewPropertyAnimator(duration: 0.34, dampingRatio: 0.92)
        animator.addAnimations {
            for snapshot in snapshots {
                snapshot.view.frame = snapshot.endFrame
            }
        }
        animator.addCompletion { [weak self, weak source, weak overlay] _ in
            DispatchQueue.main.async {
                overlay?.removeFromSuperview()
                source?.setTransitionCardsHidden(false)
                self?.animator = nil
                self?.isAnimating = false
                if direction == .exiting {
                    self?.activeSource = nil
                }
            }
        }
        self.animator = animator
        animator.startAnimation()
        return true
    }

    private func foregroundWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)
    }
}

private struct SplitFeedTransitionCoordinatorKey: EnvironmentKey {
    static let defaultValue: SplitFeedTransitionCoordinator? = nil
}

private struct SplitFeedTransitionConfigurationKey: EnvironmentKey {
    static let defaultValue: SplitFeedTransitionConfiguration? = nil
}

extension EnvironmentValues {
    var splitFeedTransitionCoordinator: SplitFeedTransitionCoordinator? {
        get { self[SplitFeedTransitionCoordinatorKey.self] }
        set { self[SplitFeedTransitionCoordinatorKey.self] = newValue }
    }

    var splitFeedTransitionConfiguration: SplitFeedTransitionConfiguration? {
        get { self[SplitFeedTransitionConfigurationKey.self] }
        set { self[SplitFeedTransitionConfigurationKey.self] = newValue }
    }
}
