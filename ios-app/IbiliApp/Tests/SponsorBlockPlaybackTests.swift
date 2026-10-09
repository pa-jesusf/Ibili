import AVFoundation
import Combine
import XCTest
@testable import Ibili

@MainActor
final class SponsorBlockPlaybackTests: XCTestCase {
    private let key = SponsorVideoKey(bvid: "BV1bY4y1v7Mb", cid: 42)
    private func segment(_ id: String, _ start: Double, _ end: Double,
                         category: SponsorCategory = .sponsor) -> SponsorSegment {
        SponsorSegment(id: id, cid: 42, category: category, start: start, end: end, videoDuration: 100)
    }

    private func fixture(_ segments: [SponsorSegment], position: Double,
                         playing: Bool = true, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async -> (SponsorBlockPlaybackCoordinator, ControlledSponsorPlayer, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = SponsorBlockRepository(directory: directory) { _, _ in segments }
        let item = ControlledSponsorItem(asset: AVMutableComposition())
        let player = ControlledSponsorPlayer(playerItem: item)
        player.position = position
        player.playing = playing
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository, now: now)
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await coordinator.waitForSynchronization()
        await drainCallbacks()
        return (coordinator, player, directory)
    }

    private func drainCallbacks() async { for _ in 0..<80 { await Task.yield() } }

    func testDisabledVideoRebindKeepsKnownMarksAndCanRestoreSkipping() async {
        let values = [segment("ad", 10, 20)]
        let (coordinator, player, directory) = await fixture(values, position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        var configuration = SponsorConfiguration()
        configuration.disabledVideos.insert(key.bvid)
        coordinator.configure(configuration)
        coordinator.detach()
        player.position = 12
        coordinator.bind(player: player, item: player.currentItem!, key: key,
                         offlineOnly: false, offlineDirectories: [], configuration: configuration, playbackAllowed: true)
        await coordinator.waitForSynchronization()
        await drainCallbacks()
        XCTAssertEqual(coordinator.segments, values)
        XCTAssertEqual(coordinator.syncState, .disabled)
        XCTAssertNil(coordinator.notice)
        XCTAssertTrue(player.seeks.isEmpty)
        configuration.disabledVideos.remove(key.bvid)
        coordinator.configure(configuration)
        await coordinator.waitForSynchronization()
        await drainCallbacks()
        XCTAssertEqual(player.position, 20)
        guard case .skipped = coordinator.notice else { return XCTFail("Restored video must skip again") }
    }

    func testDisabledVideoWithoutCacheDoesNotFetchOrInventAvailableMarks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = SponsorBlockRepository(directory: directory) { _, _ in
            XCTFail("Per-video disable must not fetch community data")
            return []
        }
        let item = ControlledSponsorItem(asset: AVMutableComposition())
        let player = ControlledSponsorPlayer(playerItem: item)
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        var configuration = SponsorConfiguration()
        configuration.disabledVideos.insert(key.bvid)
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: configuration, playbackAllowed: true)
        await coordinator.waitForSynchronization()
        XCTAssertTrue(coordinator.segments.isEmpty)
        XCTAssertEqual(coordinator.syncState, .disabled)
        XCTAssertTrue(player.seeks.isEmpty)
    }

    func testLateNativeSeekNotificationsKeepUndoAndUndoReturnsOriginalPosition() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 12)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        // Both notifications arrive after AVPlayer's seek completion handler.
        player.postJump()
        player.postJump()
        await drainCallbacks()
        guard case .skipped(_, let from, _) = coordinator.notice else {
            return XCTFail("A managed seek's late notifications must preserve the undo action")
        }
        XCTAssertEqual(from, 12)
        coordinator.performNoticeAction()
        await drainCallbacks()
        XCTAssertEqual(player.position, 12)
        XCTAssertEqual(player.seeks.count, 2)
        guard case .manual = coordinator.notice else { return XCTFail("Undo should suppress this pass") }
    }

    func testFractionalEndDoesNotLandInsideSkippedInterval() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 18.913, 32.876)], position: 20)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertGreaterThanOrEqual(player.position, 32.876)
        XCTAssertEqual(player.seeks.count, 1)
        player.postJump()
        await drainCallbacks()
        guard case .skipped = coordinator.notice else { return XCTFail("Fractional endpoint must retain undo") }
    }

    func testLaterAutomaticIntervalStillSkipsAfterFirstSeekNotification() async {
        let (coordinator, player, directory) = await fixture([segment("first", 10, 20), segment("second", 30, 40)], position: 12)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        player.postJump()
        player.position = 30.01
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertEqual(player.seeks.count, 2)
        XCTAssertGreaterThanOrEqual(player.position, 40)
        guard case .skipped(_, let from, _) = coordinator.notice else { return XCTFail("Second skip needs its own undo") }
        XCTAssertEqual(from, 30.01)
    }

    func testUndoCountdownExpiresAndManualPromptDoesNotReappearDuringSamePass() async {
        var clock: TimeInterval = 100
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 12, now: { clock })
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(coordinator.noticeSecondsRemaining, 6)
        clock += 2
        coordinator.updateNoticeCountdown()
        XCTAssertEqual(coordinator.noticeSecondsRemaining, 4)
        coordinator.performNoticeAction()
        await drainCallbacks()
        XCTAssertEqual(player.position, 12)
        guard case .manual = coordinator.notice else { return XCTFail("Undo should offer manual skip") }
        clock += 6
        coordinator.updateNoticeCountdown()
        XCTAssertNil(coordinator.notice)
        XCTAssertEqual(coordinator.noticeSecondsRemaining, 0)
        player.position = 15
        player.fireBoundaries()
        coordinator.playbackStateChanged(allowed: true)
        XCTAssertNil(coordinator.notice)
        XCTAssertEqual(player.seeks.count, 2)
        player.position = 25
        player.fireBoundaries()
        coordinator.userWillSeek(to: 12)
        player.position = 12
        player.postJump()
        guard case .manual = coordinator.notice else { return XCTFail("A new visit gets a fresh prompt") }
    }

    func testExpiredUndoCannotSeekAndNextSkipGetsFreshCountdown() async {
        var clock: TimeInterval = 100
        let (coordinator, player, directory) = await fixture([segment("first", 10, 20), segment("second", 30, 40)], position: 12, now: { clock })
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        clock += 7
        coordinator.performNoticeAction()
        XCTAssertEqual(player.seeks.count, 1)
        XCTAssertNil(coordinator.notice)
        player.position = 30.2
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertEqual(player.seeks.count, 2)
        XCTAssertEqual(coordinator.noticeSecondsRemaining, 6)
        coordinator.performNoticeAction()
        await drainCallbacks()
        XCTAssertEqual(player.position, 30.2, accuracy: 0.00001)
    }

    func testManualCategoryPromptExpiresAndNextIntervalHasIndependentPrompt() async {
        var clock: TimeInterval = 100
        let (coordinator, player, directory) = await fixture([segment("intro", 1, 10, category: .intro),
                                                             segment("outro", 20, 30, category: .outro)], position: 3, now: { clock })
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        guard case .manual = coordinator.notice else { return XCTFail("Intro is manual by default") }
        clock += 6
        coordinator.updateNoticeCountdown()
        coordinator.configure(SponsorConfiguration(enabled: true))
        XCTAssertNil(coordinator.notice)
        player.position = 21
        player.fireBoundaries()
        guard case .manual(let interval) = coordinator.notice else { return XCTFail("Next category gets its own prompt") }
        XCTAssertEqual(interval.label, SponsorCategory.outro.label)
        XCTAssertEqual(coordinator.noticeSecondsRemaining, 6)
        XCTAssertTrue(player.seeks.isEmpty)
    }

    func testPausedWaitingAndLostFocusDoNotAutomaticallySeekButResumeDoes() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 12, playing: false)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(player.seeks.isEmpty)
        player.statusOverride = .waitingToPlayAtSpecifiedRate
        coordinator.playbackStateChanged(allowed: true)
        XCTAssertTrue(player.seeks.isEmpty)
        player.statusOverride = nil
        player.playing = true
        coordinator.playbackStateChanged(allowed: false)
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertTrue(player.seeks.isEmpty)
        coordinator.playbackStateChanged(allowed: true)
        await drainCallbacks()
        XCTAssertEqual(player.seeks.count, 1)
        guard case .skipped = coordinator.notice else { return XCTFail("Returning to active playback skips once") }
        // Same player remains active during native fullscreen or PiP handoff.
        coordinator.playbackStateChanged(allowed: true)
        player.postJump()
        XCTAssertEqual(player.seeks.count, 1)
        guard case .skipped = coordinator.notice else { return XCTFail("Presentation changes must retain undo") }
    }

    func testFailureOffersManualRetryWithoutSeekLoopOrFalseUndo() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        player.succeeds = false
        player.position = 12
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertEqual(player.seeks.count, 1)
        XCTAssertEqual(player.position, 12)
        guard case .manual = coordinator.notice else { return XCTFail("Failed automatic seek offers manual retry") }
        coordinator.playbackStateChanged(allowed: true)
        XCTAssertEqual(player.seeks.count, 1)
        player.succeeds = true
        coordinator.performNoticeAction()
        await drainCallbacks()
        XCTAssertEqual(player.position, 20)
        XCTAssertNil(coordinator.notice)
    }

    func testPolicyDisableAndReplacementInvalidateQueuedBoundaryAndSeek() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        let oldCallbacks = player.boundaryCallbacks
        player.position = 12
        player.fireBoundaries()
        coordinator.configure(SponsorConfiguration(enabled: false))
        await drainCallbacks()
        XCTAssertTrue(player.seeks.isEmpty)
        coordinator.configure(SponsorConfiguration(enabled: true))
        coordinator.detach()
        player.replaceCurrentItem(with: ControlledSponsorItem(asset: AVMutableComposition()))
        oldCallbacks.forEach { $0() }
        await drainCallbacks()
        XCTAssertTrue(player.seeks.isEmpty)
        XCTAssertNil(coordinator.notice)
    }

    func testUserSeekToAnotherIntervalWhileAutomaticTaskIsQueuedWins() async {
        let (coordinator, player, directory) = await fixture([segment("first", 10, 20), segment("second", 30, 40)], position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        player.position = 12
        player.fireBoundaries()
        coordinator.userWillSeek(to: 35)
        player.position = 35
        player.postJump()
        await drainCallbacks()
        XCTAssertTrue(player.seeks.isEmpty)
        XCTAssertEqual(player.position, 35)
        guard case .manual = coordinator.notice else { return XCTFail("User seek must cancel pending auto seek") }
    }

    func testOverlapsAndTouchingIntervalsMergeButOtherCategoriesKeepPolicies() async {
        let values = [segment("a", 10, 20), segment("b", 15, 25), segment("c", 25, 30),
                      segment("intro", 29, 35, category: .intro), segment("off", 40, 50, category: .selfpromo)]
        let (coordinator, player, directory) = await fixture(values, position: 12)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(player.position, 30)
        XCTAssertEqual(player.seeks.count, 1)
        player.postJump()
        guard case .skipped = coordinator.notice else { return XCTFail("Undo takes precedence over overlapping manual label") }
        player.position = 41
        player.fireBoundaries()
        XCTAssertEqual(player.seeks.count, 1)
    }

    func testNoticeSettingDoesNotDisableSkippingAndManualCategoryRemainsAvailable() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20), segment("intro", 30, 40, category: .intro)], position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        coordinator.configure(SponsorConfiguration(enabled: true, showsNotification: false))
        player.position = 12
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertEqual(player.position, 20)
        XCTAssertNil(coordinator.notice)
        player.position = 31
        player.fireBoundaries()
        guard case .manual = coordinator.notice else { return XCTFail("Manual actions remain available") }
    }

    func testSubmittedSeekCanFinishWhilePageLosesFocusWithoutCreatingDuplicateSeek() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        player.defersCompletion = true
        player.position = 12
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertEqual(player.seeks.count, 1)
        coordinator.playbackStateChanged(allowed: false)
        coordinator.playbackStateChanged(allowed: true)
        XCTAssertEqual(player.seeks.count, 1)
        player.finishSeek()
        await drainCallbacks()
        player.postJump()
        XCTAssertEqual(player.position, 20)
        XCTAssertEqual(player.seeks.count, 1)
        guard case .skipped = coordinator.notice else { return XCTFail("Restored foreground retains completed skip undo") }
    }

    func testSuccessfulCallbackWithoutLeavingIntervalDoesNotLoopOrClaimSkip() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 0)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        player.advances = false
        player.position = 12
        player.fireBoundaries()
        await drainCallbacks()
        XCTAssertEqual(player.seeks.count, 1)
        guard case .manual = coordinator.notice else { return XCTFail("Completion alone cannot prove the playhead advanced") }
    }

    func testDifferentPlayerSessionsNeverShareSeekNoticeOrCountdown() async {
        let (first, a, firstDirectory) = await fixture([segment("a", 10, 20)], position: 12)
        let (second, b, secondDirectory) = await fixture([segment("b", 30, 40)], position: 35)
        defer {
            first.detach(); second.detach()
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        first.performNoticeAction()
        await drainCallbacks()
        XCTAssertEqual(a.position, 12)
        XCTAssertEqual(b.position, 40)
        XCTAssertEqual(b.seeks.count, 1)
        guard case .skipped = second.notice else { return XCTFail("Other session's undo remains intact") }
    }

    func testBackgroundJumpQueuedBeforeUndoCannotCancelUndo() async {
        let (coordinator, player, directory) = await fixture([segment("ad", 10, 20)], position: 12)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        let emitted = DispatchSemaphore(value: 0)
        // Hold the main actor until the background observer has captured the
        // old jump. Its delivery must happen after the new undo command.
        DispatchQueue.global().async {
            player.postJump()
            emitted.signal()
        }
        XCTAssertEqual(emitted.wait(timeout: .now() + 2), .success)
        coordinator.performNoticeAction()
        await drainCallbacks()
        XCTAssertEqual(player.seeks, [20, 12])
        XCTAssertEqual(player.position, 12)
        guard case .manual = coordinator.notice else { return XCTFail("Queued old event must not remove undo's manual prompt") }
    }

    func testNativeReplayStartsFreshAutomaticPassEvenAfterUndoSuppressedOpening() async {
        var clock: TimeInterval = 100
        let (coordinator, player, directory) = await fixture([segment("opening", 0, 20)], position: 30, now: { clock })
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        coordinator.userWillSeek(to: 0)
        player.position = 0
        player.postJump()
        guard case .manual = coordinator.notice else { return XCTFail("Deliberately returning to opening is manual") }
        let restartID = coordinator.playbackWillRestart(player: player, item: player.currentItem!)!
        // A slow replay seek still owns its jump until actual completion.
        clock += 2
        player.postJump()
        coordinator.playbackDidRestart(restartID, completed: true)
        await drainCallbacks()
        XCTAssertEqual(player.position, 20)
        XCTAssertEqual(player.seeks, [20])
        guard case .skipped = coordinator.notice else { return XCTFail("Replay must automatically skip opening again") }
    }

    func testStaleManualNoticeDoesNotJumpBackAfterPlayheadLeavesInterval() async {
        let (coordinator, player, directory) = await fixture([segment("intro", 10, 20, category: .intro)], position: 12)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        player.position = 25 // Simulate a delayed boundary delivery.
        coordinator.performNoticeAction()
        await drainCallbacks()
        XCTAssertTrue(player.seeks.isEmpty)
        XCTAssertEqual(player.position, 25)
        XCTAssertNil(coordinator.notice)
    }

    func testSheetPreviewAndSkipValidateCurrentSegmentAndPreservePause() async {
        let current = segment("intro", 10.123, 20.876, category: .intro)
        let (coordinator, player, directory) = await fixture([current], position: 5, playing: false)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        let wrongCID = SponsorSegment(id: current.id, cid: 999, category: .intro, start: 10, end: 20, videoDuration: 100)
        coordinator.preview(wrongCID)
        coordinator.skip(segment("stale", 10, 20))
        XCTAssertTrue(player.seeks.isEmpty)
        coordinator.preview(current)
        await drainCallbacks()
        XCTAssertEqual(player.position, current.start, accuracy: 0.00002)
        XCTAssertEqual(player.timeControlStatus, .paused)
        coordinator.skip(current)
        await drainCallbacks()
        XCTAssertGreaterThanOrEqual(player.position, current.end)
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertEqual(player.seeks.count, 2)
    }

    func testOldReplayCompletionCannotOverwriteNewUserSeek() async {
        let (coordinator, player, directory) = await fixture([segment("opening", 0, 20)], position: 30)
        defer { coordinator.detach(); try? FileManager.default.removeItem(at: directory) }
        let restartID = coordinator.playbackWillRestart(player: player, item: player.currentItem!)!
        coordinator.userWillSeek(to: 12)
        player.position = 12
        player.postJump()
        coordinator.playbackDidRestart(restartID, completed: true)
        await drainCallbacks()
        XCTAssertTrue(player.seeks.isEmpty)
        guard case .manual = coordinator.notice else { return XCTFail("New user intent must remain authoritative") }
    }
}

private final class ControlledSponsorItem: AVPlayerItem {
    override var duration: CMTime { CMTime(seconds: 100, preferredTimescale: 600) }
}

private final class ControlledSponsorPlayer: AVPlayer {
    var position = 0.0
    var playing = false
    var seeks: [Double] = []
    var succeeds = true
    var advances = true
    var defersCompletion = false
    private var pendingSeek: (time: CMTime, item: AVPlayerItem?, completion: (Bool) -> Void)?
    var statusOverride: AVPlayer.TimeControlStatus?
    var boundaryCallbacks: [() -> Void] { Array(boundaries.values) }
    private var boundaries: [UUID: () -> Void] = [:]
    override var timeControlStatus: AVPlayer.TimeControlStatus { statusOverride ?? (playing ? .playing : .paused) }
    override func currentTime() -> CMTime { CMTime(seconds: position, preferredTimescale: 600_000) }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping (Bool) -> Void) {
        seeks.append(time.seconds)
        if defersCompletion {
            pendingSeek = (time, currentItem, completionHandler)
            return
        }
        if succeeds && advances { position = time.seconds }
        completionHandler(succeeds)
    }
    override func addBoundaryTimeObserver(forTimes times: [NSValue], queue: DispatchQueue?, using block: @escaping () -> Void) -> Any {
        let id = UUID()
        boundaries[id] = block
        return id
    }
    override func removeTimeObserver(_ observer: Any) {
        if let id = observer as? UUID { boundaries[id] = nil }
    }
    func fireBoundaries() { Array(boundaries.values).forEach { $0() } }
    func postJump() { NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: currentItem) }
    func finishSeek() {
        guard let pendingSeek else { return }
        self.pendingSeek = nil
        let success = succeeds && currentItem === pendingSeek.item
        if success && advances { position = pendingSeek.time.seconds }
        pendingSeek.completion(success)
    }
}
