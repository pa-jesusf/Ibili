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
                guard link == nil else { return }
                link = DisplayLinkBox()
            }
            .onDisappear {
                link?.stop()
                link = nil
            }
    }
}

private final class DisplayLinkBox {
    private var displayLink: CADisplayLink?

    init() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 120, maximum: 120, preferred: 120
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
