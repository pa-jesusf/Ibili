import SwiftUI
import UIKit

/// Requests a higher CADisplayLink preferred frame rate while the
/// user is actively scrolling. On ProMotion devices (iPhone 13 Pro+)
/// this requests 120 Hz during scroll tracking while the system
/// naturally drops back to lower rates when idle.
///
/// The display link is attached to `.tracking` run-loop mode only, so
/// it doesn't fire during idle and has zero battery cost when the user
/// isn't scrolling.
///
/// Usage: `.modifier(ProMotionScrollHint())`
struct ProMotionScrollHint: ViewModifier {
    @State private var link: DisplayLinkBox?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard link == nil,
                      UIScreen.main.maximumFramesPerSecond > 60 else { return }
                link = DisplayLinkBox(maximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond)
            }
            .onDisappear {
                link?.stop()
                link = nil
            }
    }
}

private final class DisplayLinkBox {
    private var displayLink: CADisplayLink?

    init(maximumFramesPerSecond: Int) {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            let fps = Float(min(maximumFramesPerSecond, 120))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: fps, maximum: fps, preferred: fps
            )
        }
        link.add(to: .main, forMode: .tracking)
        displayLink = link
    }

    @objc private func tick() {}

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit { stop() }
}
