import Combine
import UIKit

/// Intrinsic-sized native capsule: only its visible buttons intercept touches.
/// Mounting in AVKit's public contentOverlayView also carries it into fullscreen.
@MainActor
final class SponsorBlockBadgeView: UIVisualEffectView {
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let countdownLabel = UILabel()
    private var subscription: AnyCancellable?
    private weak var coordinator: SponsorBlockPlaybackCoordinator?

    init(coordinator: SponsorBlockPlaybackCoordinator) {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
        else { effect = UIBlurEffect(style: .systemMaterial) }
        super.init(effect: effect)
        self.coordinator = coordinator
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        clipsToBounds = true
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countdownLabel.textColor = .secondaryLabel
        countdownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countdownLabel.isAccessibilityElement = false
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addTarget(self, action: #selector(performAction), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button, countdownLabel])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        subscription = coordinator.$notice.combineLatest(coordinator.$noticeSecondsRemaining)
            .sink { [weak self] notice, remaining in
            self?.update(notice, remaining: remaining)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); layer.cornerRadius = bounds.height / 2 }

    private func update(_ notice: SponsorNotice?, remaining: Int) {
        isHidden = notice == nil || remaining <= 0
        guard let notice else { return }
        countdownLabel.text = "\(remaining)s"
        switch notice {
        case .manual:
            label.isHidden = true
            button.setTitle(notice.label, for: .normal)
        case .skipped:
            label.isHidden = false
            label.text = notice.label
            button.setTitle("撤销", for: .normal)
        }
        accessibilityLabel = notice.label
    }

    @objc private func performAction() { coordinator?.performNoticeAction() }
}
