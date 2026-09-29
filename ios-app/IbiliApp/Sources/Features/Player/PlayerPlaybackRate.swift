import AVFoundation

extension AVPlayer {
    /// Native AVKit owns speed selection. While paused, retain its last
    /// displayed speed instead of presenting the transport rate (zero).
    var preferredPlaybackRate: Float {
        if rate.isFinite, rate > 0 { return rate }
        return defaultRate.isFinite && defaultRate > 0 ? defaultRate : 1
    }

    /// Observe the actual speed, not a remembered pre-fullscreen preference.
    /// This never changes the transport rate or resumes a paused player.
    @MainActor
    func synchronizeDefaultRateWithPlayback() {
        guard rate.isFinite, rate > 0, defaultRate != rate else { return }
        defaultRate = rate
    }

    /// Only explicit user actions (e.g. temporary long-press acceleration)
    /// may write rate. Same-value writes can generate another status callback.
    @MainActor
    @discardableResult
    func setUserPlaybackRate(_ desiredRate: Float) -> Bool {
        guard desiredRate.isFinite, desiredRate > 0 else { return false }
        var changed = false
        if defaultRate != desiredRate {
            defaultRate = desiredRate
            changed = true
        }
        if (timeControlStatus == .playing || rate > 0), rate != desiredRate {
            rate = desiredRate
            changed = true
        }
        return changed
    }
}
