import AVFoundation
import UIKit

@MainActor
final class SubtitleController {
    private(set) var overlayView: SubtitleOverlayView?

    @discardableResult
    func prepareOverlay() -> SubtitleOverlayView {
        if overlayView == nil {
            overlayView = SubtitleOverlayView()
        }
        return overlayView!
    }

    func setTrack(_ track: SubtitleTrackDTO?) {
        prepareOverlay().setTrack(track)
    }

    func setVisible(_ visible: Bool) {
        prepareOverlay().setVisible(visible)
    }

    func attach(_ player: AVPlayer) {
        prepareOverlay().attach(player)
    }

    func detach() {
        overlayView?.detach()
    }
}

private final class PaddedSubtitleLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10) {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetBounds = bounds.inset(by: textInsets)
        let rect = super.textRect(forBounds: insetBounds, limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(
            top: -textInsets.top,
            left: -textInsets.left,
            bottom: -textInsets.bottom,
            right: -textInsets.right
        ))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }
}

@MainActor
final class SubtitleOverlayView: UIView {
    private let label = PaddedSubtitleLabel()
    private var cues: [SubtitleCueDTO] = []
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var visible = false
    private var lastCueID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setTrack(_ track: SubtitleTrackDTO?) {
        cues = track?.items.sorted { $0.fromSec < $1.fromSec } ?? []
        lastCueID = nil
        update(for: player?.currentTime().seconds ?? 0)
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        update(for: player?.currentTime().seconds ?? 0)
    }

    func attach(_ player: AVPlayer) {
        if self.player === player { return }
        detach()
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.update(for: time.seconds)
            }
        }
        update(for: player.currentTime().seconds)
    }

    func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        label.isHidden = true
    }

    private func setup() {
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.isHidden = true
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            label.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -34),
        ])
    }

    private func update(for seconds: Double) {
        guard visible, !cues.isEmpty, seconds.isFinite else {
            lastCueID = nil
            label.isHidden = true
            label.text = nil
            return
        }
        guard let cue = cue(at: seconds) else {
            lastCueID = nil
            label.isHidden = true
            label.text = nil
            return
        }
        if cue.id != lastCueID {
            lastCueID = cue.id
            label.text = cue.content
        }
        label.isHidden = false
    }

    private func cue(at seconds: Double) -> SubtitleCueDTO? {
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].fromSec <= seconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        guard cues.indices.contains(index) else { return nil }
        let cue = cues[index]
        return seconds < cue.toSec ? cue : nil
    }
}
