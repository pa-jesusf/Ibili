import UIKit
import Combine

/// The same glass panel is hosted in a scene window in every playback mode.
@MainActor
final class InteractiveVideoOverlayView: UIVisualEffectView {
    private let titleLabel = UILabel()
    private let countdownLabel = UILabel()
    private let historyButton = UIButton(type: .system)
    private let buttons = UIStackView()
    private let scrollView = UIScrollView()
    private var subscription: AnyCancellable?
    private weak var coordinator: InteractiveVideoCoordinator?
    private var lastPresentation = InteractivePresentation()
    private var lastHistory: [InteractiveHistoryEntry] = []

    init(coordinator: InteractiveVideoCoordinator) {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
        else { effect = UIBlurEffect(style: .systemMaterial) }
        super.init(effect: effect)
        self.coordinator = coordinator
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countdownLabel.textColor = IbiliTheme.accentUIColor
        countdownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        historyButton.setImage(UIImage(systemName: "clock.arrow.circlepath"), for: .normal)
        historyButton.tintColor = IbiliTheme.accentUIColor
        historyButton.showsMenuAsPrimaryAction = true
        historyButton.accessibilityLabel = "剧情回溯"
        historyButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        historyButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let header = UIStackView(arrangedSubviews: [titleLabel, countdownLabel, historyButton])
        header.spacing = 12
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)
        buttons.axis = .vertical; buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        contentView.addSubview(scrollView)
        scrollView.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        // Content determines the preferred height; the screen safe area caps
        // it on short landscape screens, leaving choices scrollable.
        let preferredHeight = scrollView.heightAnchor.constraint(equalTo: buttons.heightAnchor)
        preferredHeight.priority = .defaultHigh
        preferredHeight.isActive = true
        subscription = Publishers.CombineLatest(coordinator.$presentation.removeDuplicates(), coordinator.$history.removeDuplicates())
            .sink { [weak self] presentation, history in
                self?.update(presentation, history: history)
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update(_ value: InteractivePresentation, history: [InteractiveHistoryEntry]) {
        isHidden = value.phase == .hidden
        titleLabel.text = value.title
        historyButton.isHidden = !value.showsHistoryControl || history.isEmpty
        if lastHistory != history {
            lastHistory = history
            historyButton.menu = UIMenu(title: "剧情回溯", children: history.enumerated().map { index, entry in
                UIAction(title: "\(index + 1). \(entry.title.isEmpty ? "剧情" : entry.title)",
                         state: entry.id == history.last?.id ? .on : .off) { [weak coordinator] _ in
                    coordinator?.rewind(to: entry.id)
                }
            })
        }
        countdownLabel.isHidden = value.secondsRemaining == nil
        countdownLabel.text = value.secondsRemaining.map { "\($0)s" }
        // A countdown only changes its label, never rebuilds the button tree.
        guard value.phase != lastPresentation.phase || value.choices != lastPresentation.choices else {
            lastPresentation = value; return
        }
        lastPresentation = value
        buttons.arrangedSubviews.forEach { buttons.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch value.phase {
        case .choices:
            for choice in value.choices {
                addButton(choice.option.isEmpty ? "继续" : choice.option) { [weak coordinator] in coordinator?.choose(choice) }
            }
        case .failed:
            addButton("重试") { [weak coordinator] in coordinator?.retry() }
            addButton("重新开始") { [weak coordinator] in coordinator?.restart() }
        case .ending:
            addButton("重新开始剧情") { [weak coordinator] in coordinator?.restart() }
        case .loading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating(); buttons.addArrangedSubview(spinner)
        case .hidden: break
        }
        scrollView.setContentOffset(.zero, animated: false)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.baseForegroundColor = IbiliTheme.accentUIColor
        config.baseBackgroundColor = IbiliTheme.accentUIColor
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        button.configuration = config
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        buttons.addArrangedSubview(button)
    }
}
