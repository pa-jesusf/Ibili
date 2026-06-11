import UIKit

final class FeedCollectionHeaderGradientView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        guard let layer = layer as? CAGradientLayer else { return }
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.locations = [0, 0.48, 1]
        updateColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        guard let layer = layer as? CAGradientLayer else { return }
        layer.colors = [
            UIColor.black.withAlphaComponent(0.30).cgColor,
            UIColor.black.withAlphaComponent(0.14).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor
        ]
    }
}
