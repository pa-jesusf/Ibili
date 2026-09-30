import AVFoundation
import XCTest
#if canImport(IbiliPlayerRuntime)
@testable import IbiliPlayerRuntime
#else
@testable import Ibili
#endif

final class PlayerTimeControlObservationTests: XCTestCase {
    @MainActor
    func testMainThreadPauseIsDeliveredBeforeNavigationCanReactivate() {
        let player = ObservedPlayer()
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.interfaceDidAppear)
        let observation = PlayerTimeControlObservation(player: player) { _, status in
            state.apply(.observedTimeControlStatus(status))
        }
        defer { observation.invalidate() }
        state.apply(.interfaceDeactivated)
        player.sendStatus(.paused)
        state.apply(.interfaceActivated)
        XCTAssertEqual(state.intent, .play)
        state.apply(.interfaceDidAppear)
        player.sendStatus(.playing)
        player.sendStatus(.paused)
        // This assertion fails if observations are deferred to a Task: a
        // native user pause must be visible before a subsequent push.
        XCTAssertEqual(state.intent, .pause)
    }

    @MainActor
    func testInvalidatedObservationDoesNotReceiveFurtherNativeCallbacks() {
        let player = ObservedPlayer()
        var count = 0
        let observation = PlayerTimeControlObservation(player: player) { _, _ in count += 1 }
        player.sendStatus(.paused)
        XCTAssertEqual(count, 1)
        observation.invalidate()
        player.sendStatus(.playing)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testAttachingNewPausedTransportAfterPageAppearedDoesNotCancelAutoplay() {
        let player = ObservedPlayer()
        player.sendStatus(.paused)
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.interfaceDidAppear)
        let observation = PlayerTimeControlObservation(player: player) { _, status in
            state.apply(.observedTimeControlStatus(status))
        }
        defer { observation.invalidate() }
        XCTAssertEqual(state.intent, .play)
        player.sendStatus(.playing)
        player.sendStatus(.paused)
        XCTAssertEqual(state.intent, .pause)
    }

    @MainActor
    func testActualAVPlayerPausePreservesNavigationIntent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ibili-lifecycle-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 441000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        try file.write(from: buffer)

        let player = AVPlayer(url: url)
        player.isMuted = true
        var state = PlayerSessionBehaviorState()
        state.apply(.interfaceActivated)
        state.apply(.interfaceDidAppear)
        let started = expectation(description: "real AVPlayer starts")
        var fulfilled = false
        let observation = PlayerTimeControlObservation(player: player) { _, status in
            state.apply(.observedTimeControlStatus(status))
            if status == .playing, !fulfilled {
                fulfilled = true
                started.fulfill()
            }
        }
        defer {
            observation.invalidate()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        player.playImmediately(atRate: 1)
        await fulfillment(of: [started], timeout: 5)
        state.apply(.interfaceDeactivated)
        player.pause()
        state.apply(.interfaceActivated)
        // Let any non-main KVO delivery run before UIKit completes appearance.
        await Task.yield()
        XCTAssertEqual(state.intent, .play)
        state.apply(.interfaceDidAppear)
        player.playImmediately(atRate: 1)
        XCTAssertGreaterThan(player.rate, 0)
        player.pause()
        XCTAssertEqual(state.intent, .pause)
    }
}

/// Uses real NSObject KVO, with deterministic AVKit transition ordering.
private final class ObservedPlayer: AVPlayer {
    private var storedStatus: AVPlayer.TimeControlStatus = .playing
    override var timeControlStatus: AVPlayer.TimeControlStatus { storedStatus }

    func sendStatus(_ status: AVPlayer.TimeControlStatus) {
        willChangeValue(forKey: "timeControlStatus")
        storedStatus = status
        didChangeValue(forKey: "timeControlStatus")
    }
}
