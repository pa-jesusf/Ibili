import SwiftUI
import AVFoundation
import Combine

/// Lightweight danmaku controller that owns a `DanmakuCanvasView` and
/// connects it to the player's time updates.
///
/// Not an `ObservableObject` — the canvas view drives its own
/// CADisplayLink rendering loop, so no SwiftUI body re-evaluations
/// are needed for danmaku animation.
@MainActor
final class DanmakuController {
    private(set) var canvasView: DanmakuCanvasView?

    func setItems(_ items: [DanmakuItemDTO]) {
        ensureCanvas()
        canvasView?.setItems(items)
    }

    func attach(_ player: AVPlayer) {
        ensureCanvas()
        canvasView?.attach(player)
    }

    func detach() {
        canvasView?.detach()
    }

    private func ensureCanvas() {
        if canvasView == nil {
            canvasView = DanmakuCanvasView()
        }
    }
}

// MARK: - SwiftUI bridge

/// Hosts the `DanmakuCanvasView` inside the player's content overlay.
/// The opacity binding lets the player hide/show danmaku without
/// tearing down the canvas.
struct DanmakuOverlay: View {
    let controller: DanmakuController
    let opacity: Double

    var body: some View {
        DanmakuCanvasRepresentable(controller: controller)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

private struct DanmakuCanvasRepresentable: UIViewRepresentable {
    let controller: DanmakuController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        if let canvas = controller.canvasView {
            canvas.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(canvas)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: container.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let canvas = controller.canvasView else { return }
        if canvas.superview !== uiView {
            canvas.translatesAutoresizingMaskIntoConstraints = false
            uiView.addSubview(canvas)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: uiView.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: uiView.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: uiView.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: uiView.bottomAnchor),
            ])
        }
    }
}
