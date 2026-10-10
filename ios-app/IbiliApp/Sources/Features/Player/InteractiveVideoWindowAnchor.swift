import UIKit
import Combine

/// AVKit carries this anchor into fullscreen. Its scene hosts one floating
/// window, whose size is independent of the inline video's bounds.
@MainActor
final class InteractiveVideoWindowAnchor: UIView {
    private let coordinator: InteractiveVideoCoordinator
    private var subscription: AnyCancellable?
    private var floatingWindow: InteractiveVideoFloatingWindow?
    private var shouldShowPrompt = false
    private var isInvalidated = false

    init(coordinator: InteractiveVideoCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        subscription = coordinator.floatingPresentationPublisher.sink { [weak self] visible in
            self?.shouldShowPrompt = visible
            self?.updatePresentation()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePresentation()
    }

    func invalidate() {
        isInvalidated = true
        subscription?.cancel(); subscription = nil
        discardWindow()
    }

    private func updatePresentation() {
        guard !isInvalidated, let source = window, let scene = source.windowScene else {
            discardWindow()
            return
        }
        guard shouldShowPrompt else {
            floatingWindow?.isHidden = true
            return
        }
        if floatingWindow?.windowScene !== scene {
            discardWindow()
            let floating = InteractiveVideoFloatingWindow(windowScene: scene)
            floating.frame = scene.coordinateSpace.bounds
            floating.backgroundColor = .clear
            floating.rootViewController = InteractiveVideoFloatingController(coordinator: coordinator)
            floatingWindow = floating
        }
        // Showing without makeKeyAndVisible leaves the app's key window,
        // native fullscreen controller and playback lifecycle untouched.
        floatingWindow?.windowLevel = UIWindow.Level(rawValue: source.windowLevel.rawValue + 1)
        floatingWindow?.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        floatingWindow?.isHidden = false
    }

    private func discardWindow() {
        floatingWindow?.isHidden = true
        floatingWindow?.rootViewController = nil
        floatingWindow = nil
    }
}

private final class InteractiveVideoFloatingWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        // Only the floating panel consumes touches. AVKit and navigation
        // continue to receive gestures outside it.
        return target === rootViewController?.view ? nil : target
    }
}

@MainActor
private final class InteractiveVideoFloatingController: UIViewController {
    private let coordinator: InteractiveVideoCoordinator

    init(coordinator: InteractiveVideoCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        let panel = InteractiveVideoOverlayView(coordinator: coordinator)
        view.addSubview(panel)
        let preferredWidth = panel.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            panel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32),
            preferredWidth,
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.8),
        ])
    }
}
