import AVFoundation
import XCTest
@testable import Ibili

final class PlayerPlaybackRateTests: XCTestCase {
    @MainActor
    func testStableRateNeverWritesBackToPlayer() {
        let player = RatePlayerDouble(status: .playing, rate: 2, defaultRate: 2)
        for _ in 0..<1000 { player.synchronizeDefaultRateWithPlayback() }
        XCTAssertEqual(player.rateWrites, 0)
        XCTAssertEqual(player.defaultRateWrites, 0)
    }

    @MainActor
    func testFullscreenRateResetIsAcceptedAndDisplayed() {
        let player = RatePlayerDouble(status: .playing, rate: 1, defaultRate: 2)
        player.synchronizeDefaultRateWithPlayback()
        player.synchronizeDefaultRateWithPlayback()
        XCTAssertEqual(player.rate, 1)
        XCTAssertEqual(player.preferredPlaybackRate, 1)
        XCTAssertEqual(player.defaultRate, 1)
        XCTAssertEqual(player.rateWrites, 0)
        XCTAssertEqual(player.defaultRateWrites, 1)
    }

    @MainActor
    func testPausedPlayerKeepsPausedAndRemembersNextPlayRate() {
        let player = RatePlayerDouble(status: .paused, rate: 0, defaultRate: 2)
        player.synchronizeDefaultRateWithPlayback()
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.defaultRate, 2)
        XCTAssertEqual(player.preferredPlaybackRate, 2)
        XCTAssertEqual(player.rateWrites, 0)
        XCTAssertEqual(player.defaultRateWrites, 0)
    }

    @MainActor
    func testBufferingAndTemporaryBoostRestoreChosenSpeed() {
        let player = RatePlayerDouble(status: .waitingToPlayAtSpecifiedRate, rate: 1.5, defaultRate: 1.5)
        let restore = player.preferredPlaybackRate
        XCTAssertTrue(player.setUserPlaybackRate(2))
        XCTAssertFalse(player.setUserPlaybackRate(2))
        XCTAssertTrue(player.setUserPlaybackRate(restore))
        XCTAssertFalse(player.setUserPlaybackRate(restore))
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertEqual(player.rateWrites, 2)
        for invalid in [Float.nan, .infinity, 0, -1] { XCTAssertFalse(player.setUserPlaybackRate(invalid)) }
        XCTAssertEqual(player.rateWrites, 2)
    }

    /// Runs actual AVFoundation KVO, not a simulated notification source.
    @MainActor
    func testNativePlayingObserverSettlesInsteadOfFeedingBackAtOneAndTwoX() async throws {
        let url = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        for desiredRate: Float in [1, 2] {
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            let started = expectation(description: "native player started at \(desiredRate)x")
            var playingCallbacks = 0
            var active = true
            let observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
                Task { @MainActor in
                    guard active, player.timeControlStatus == .playing else { return }
                    playingCallbacks += 1
                    if playingCallbacks == 1 { started.fulfill() }
                    // Bound a failing regression so it cannot flood the test host.
                    if playingCallbacks < 100 { player.synchronizeDefaultRateWithPlayback() }
                }
            }
            player.playImmediately(atRate: desiredRate)
            await fulfillment(of: [started], timeout: 5)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertLessThan(playingCallbacks, 10, "same-value writes caused a native KVO feedback loop")
            XCTAssertEqual(player.rate, desiredRate)
            XCTAssertGreaterThan(player.currentTime().seconds, 0)
            // Model AVKit resetting the effective rate on fullscreen exit.
            // Accept the actual speed and update its displayed default, without
            // writing the old desired rate back into the transport.
            let callbacksBeforeReset = playingCallbacks
            player.defaultRate = 2
            player.rate = 1
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(player.rate, 1)
            XCTAssertEqual(player.defaultRate, 1)
            XCTAssertLessThan(playingCallbacks - callbacksBeforeReset, 10)
            player.pause()
            try await Task.sleep(nanoseconds: 50_000_000)
            player.synchronizeDefaultRateWithPlayback()
            XCTAssertEqual(player.rate, 0)
            active = false
            observation.invalidate()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func makeSilentAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ibili-rate-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 441000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        try file.write(from: buffer)
        return url
    }
}

private final class RatePlayerDouble: AVPlayer {
    private var storedRate: Float
    private var storedDefaultRate: Float
    private let observedStatus: AVPlayer.TimeControlStatus
    private(set) var rateWrites = 0
    private(set) var defaultRateWrites = 0

    init(status: AVPlayer.TimeControlStatus, rate: Float, defaultRate: Float) {
        observedStatus = status
        storedRate = rate
        storedDefaultRate = defaultRate
        super.init()
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus { observedStatus }
    override var rate: Float {
        get { storedRate }
        set { rateWrites += 1; storedRate = newValue }
    }
    override var defaultRate: Float {
        get { storedDefaultRate }
        set { defaultRateWrites += 1; storedDefaultRate = newValue }
    }
}
