import AVFoundation
import Combine
import XCTest
@testable import Ibili

final class SponsorBlockTests: XCTestCase {
    private let key = SponsorVideoKey(bvid: "BV1bY4y1v7Mb", cid: 42)
    private func segment(_ id: String, _ start: Double, _ end: Double,
                         category: SponsorCategory = .sponsor, duration: Double = 100) -> SponsorSegment {
        SponsorSegment(id: id, cid: 42, category: category, start: start, end: end, videoDuration: duration)
    }

    func testDurationAndCIDValidationKeepsFractionalPrecision() {
        let value = segment("x", 18.913, 32.876)
        XCTAssertTrue(value.isValid(for: key, duration: 101.9))
        XCTAssertFalse(value.isValid(for: key, duration: 102.1))
        XCTAssertFalse(value.isValid(for: SponsorVideoKey(bvid: key.bvid, cid: 43), duration: 100))
        XCTAssertFalse(segment("bad", 10, .infinity).isValid(for: key, duration: 100))
        XCTAssertFalse(segment("reverse", 10, 2).isValid(for: key, duration: 100))
        XCTAssertFalse(segment("overflow", 80, 110).isValid(for: key, duration: 100))
        XCTAssertFalse(segment("unknown", 1, 2, duration: -1).isValid(for: key, duration: 100))
        XCTAssertTrue(segment("unknown", 1, 2, duration: 0).isValid(for: key, duration: 100))
    }

    func testDefaultPoliciesAndPerVideoDisable() {
        var value = SponsorConfiguration()
        XCTAssertTrue(value.isEnabled(for: key.bvid))
        XCTAssertEqual(value.policy(for: .sponsor), .automatic)
        XCTAssertEqual(value.policy(for: .intro), .manual)
        XCTAssertEqual(value.policy(for: .selfpromo), .disabled)
        value.disabledVideos.insert(key.bvid)
        XCTAssertFalse(value.isEnabled(for: key.bvid))
        XCTAssertTrue(value.isEnabled(for: "BV1fk4y1E7r3"))
    }

    func testSlowCommunityServiceCannotBlockBilibiliReadsOrWrites() async throws {
        let entered = expectation(description: "Community request is in progress")
        let independent = expectation(description: "Bilibili requests complete independently")
        independent.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let core = CoreClient { method, _ in
            switch method {
            case "sponsor_block.segments":
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                return #"{"ok":true,"data":[]}"#
            case "feed.home":
                independent.fulfill()
                return #"{"ok":true,"data":{"items":[],"has_more":false,"next_idx":0}}"#
            case "interaction.dislike":
                independent.fulfill()
                return #"{"ok":true,"data":{}}"#
            default: throw URLError(.badServerResponse)
            }
        }
        let community = Task { try await core.fetchSponsorSegments(bvid: key.bvid, cid: key.cid, forceRefresh: false, version: "test") }
        await fulfillment(of: [entered], timeout: 2)
        let read = Task { try await core.perform { try $0.feedHome() } }
        let write = Task { try await core.perform { try $0.archiveDislike(aid: 1) } }
        await fulfillment(of: [independent], timeout: 2)
        release.signal()
        _ = try await community.value
        _ = try await read.value
        try await write.value
    }

    func testOverlappingAutomaticSegmentsSeekToCombinedEnd() {
        var timeline = SponsorTimeline()
        timeline.configure(segments: [segment("a", 1.25, 5), segment("b", 4, 9.75),
                                      segment("intro", 10, 15, category: .intro)],
                           configuration: SponsorConfiguration(enabled: true))
        XCTAssertEqual(timeline.automaticInterval(at: 4.5)?.end, 9.75)
        XCTAssertNil(timeline.automaticInterval(at: 9.75))
        XCTAssertEqual(timeline.manualInterval(at: 12)?.label, SponsorCategory.intro.label)
        XCTAssertEqual(timeline.boundaries, [1.25, 9.75, 10, 15])
    }

    func testUserSeekAndUndoSuppressOnlyThisPlaybackPass() {
        var timeline = SponsorTimeline()
        let values = [segment("a", 1, 5), segment("b", 4, 9)]
        timeline.configure(segments: values, configuration: SponsorConfiguration(enabled: true))
        timeline.seekedByUser(to: 3)
        timeline.updatePass(at: 4.5)
        XCTAssertNil(timeline.automaticInterval(at: 4.5))
        XCTAssertEqual(timeline.manualInterval(at: 4.5)?.end, 9)
        // Refreshing annotations does not reset a user's choice mid-interval.
        timeline.configure(segments: values, configuration: SponsorConfiguration(enabled: true))
        XCTAssertNil(timeline.automaticInterval(at: 7))
        timeline.updatePass(at: 10)
        XCTAssertNotNil(timeline.automaticInterval(at: 3))
    }

    func testPositiveAndNegativeCacheExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let positive = SponsorSnapshot(schemaVersion: 1, key: key, fetchedAt: now, segments: [segment("a", 1, 2)])
        let empty = SponsorSnapshot(schemaVersion: 1, key: key, fetchedAt: now, segments: [])
        XCTAssertTrue(positive.isFresh(at: now.addingTimeInterval(3599)))
        XCTAssertFalse(positive.isFresh(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(empty.isFresh(at: now.addingTimeInterval(899)))
        XCTAssertFalse(empty.isFresh(at: now.addingTimeInterval(900)))
        XCTAssertFalse(positive.isFresh(at: now.addingTimeInterval(-1)))
    }

    func testCoalescingAndPersistenceUseRealRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SponsorRequestGate()
        let repository = SponsorBlockRepository(directory: directory) { _, _ in try await gate.fetch() }
        let first = Task { try await repository.refresh(self.key) }
        await gate.waitForRequest()
        let second = Task { try await repository.refresh(self.key) }
        await Task.yield()
        await gate.succeed([segment("a", 1, 2)])
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, secondResult)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        let reloaded = SponsorBlockRepository(directory: directory) { _, _ in XCTFail("Cache read should not fetch"); return [] }
        let disk = await reloaded.cached(key)
        XCTAssertEqual(disk, firstResult)
    }

    func testFailedRefreshPreservesCacheAndOfflineSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let offlineDirectory = directory.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: offlineDirectory.appendingPathComponent("metadata.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SponsorRequestGate()
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in try await gate.fetch() }
        let initial = Task { try await repository.refresh(self.key) }
        await gate.waitForRequest()
        await gate.succeed([segment("a", 1, 2)])
        let snapshot = try await initial.value
        await repository.pin(snapshot, to: offlineDirectory)
        let refresh = Task { try await repository.refresh(self.key, force: true) }
        await gate.waitForRequest()
        await gate.fail()
        do { _ = try await refresh.value; XCTFail("Must report service failure") } catch {}
        let cached = await repository.cached(key)
        XCTAssertEqual(cached, snapshot)
        await repository.clear()
        let empty = await repository.cached(key)
        XCTAssertNil(empty)
        let pinned = await repository.cached(key, offlineDirectory: offlineDirectory)
        XCTAssertEqual(pinned, snapshot)
    }

    func testClearDuringNetworkRequestCannotResurrectCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SponsorRequestGate()
        let repository = SponsorBlockRepository(directory: directory) { _, _ in try await gate.fetch() }
        let request = Task { try await repository.refresh(self.key) }
        await gate.waitForRequest()
        await repository.clear()
        await gate.succeed([segment("late", 1, 2)])
        _ = try await request.value
        let value = await repository.cached(key)
        XCTAssertNil(value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(key.fileName).path))
    }

    @MainActor
    func testReplacedItemRejectsLateResponseAndDetachRemovesState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SponsorRequestGate()
        let repository = SponsorBlockRepository(directory: directory) { _, _ in try await gate.fetch() }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        let first = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: first)
        coordinator.bind(player: player, item: first, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await gate.waitForRequest()
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        await gate.succeed([segment("late", 1, 2)])
        // Drain actor continuations rather than waiting for a wall-clock timer.
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(coordinator.segments.isEmpty)
        XCTAssertNil(coordinator.notice)
        coordinator.detach()
        XCTAssertNil(coordinator.key)
        XCTAssertEqual(coordinator.syncState, .disabled)
    }

    @MainActor
    func testOfflineOnlyDoesNotRequestNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SponsorBlockRepository(directory: directory) { _, _ in XCTFail("Offline playback must not fetch"); return [] }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        coordinator.bind(player: player, item: item, key: key, offlineOnly: true, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: false)
        let completed = expectation(description: "Offline lookup completes")
        var subscription: AnyObject?
        subscription = coordinator.$syncState.sink { state in if state == .offlineEmpty { completed.fulfill() } }
        await fulfillment(of: [completed], timeout: 5)
        _ = subscription
        coordinator.refresh()
        XCTAssertEqual(coordinator.syncState, .offlineEmpty)
        XCTAssertNil(coordinator.notice)
        coordinator.detach()
    }

    @MainActor
    func testActualPlayerPausedSyncThenPlaySkipsAndUndoPreservesRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = try await readyPlayer(in: directory)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let positioned = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        let values = [segment("ad", 2, 6, duration: 10), segment("overlap", 5, 8, duration: 10)]
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in values }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach() }
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await waitForSync(coordinator)
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.05)
        XCTAssertNil(coordinator.notice)

        let skipped = expectation(description: "Merged automatic skip")
        var subscription = coordinator.$notice.sink { value in
            if case .skipped = value { skipped.fulfill() }
        }
        await beginPlaying(player, coordinator: coordinator, rate: 1.5)
        await fulfillment(of: [skipped], timeout: 5)
        subscription.cancel()
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 8)
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.05)
        guard case .skipped(_, let from, _) = coordinator.notice else { return XCTFail("Expected undo notice") }
        XCTAssertEqual(from, 3, accuracy: 0.4)

        let undone = expectation(description: "Undo yields manual skip")
        subscription = coordinator.$notice.sink { value in
            if case .manual = value { undone.fulfill() }
        }
        coordinator.performNoticeAction()
        await fulfillment(of: [undone], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(player.currentTime().seconds, from, accuracy: 0.4)
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.05)
        player.pause()
        coordinator.playbackStateChanged(allowed: false)
        XCTAssertNil(coordinator.notice)
    }

    @MainActor
    func testActualNativeSeekIntoAnnotationShowsManualSkipAndKeepsPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = try await readyPlayer(in: directory)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let values = [segment("ad", 2, 8, duration: 10)]
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in values }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach() }
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await waitForSync(coordinator)
        let manual = expectation(description: "External seek offers manual skip")
        let subscription = coordinator.$notice.sink { value in
            if case .manual = value { manual.fulfill() }
        }
        let completed = await player.seek(to: CMTime(seconds: 3.25, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(completed)
        await fulfillment(of: [manual], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(player.currentTime().seconds, 3.25, accuracy: 0.05)
        XCTAssertEqual(player.timeControlStatus, .paused)
        coordinator.performNoticeAction()
        let jumped = expectation(description: "Manual skip completed")
        let token = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { _ in
            if player.currentTime().seconds >= 8 { jumped.fulfill() }
        }
        await fulfillment(of: [jumped], timeout: 5)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(player.currentTime().seconds, 8, accuracy: 0.05)
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor
    func testActualSeekWhilePlayingRemainsManualAndKeepsRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = try await readyPlayer(in: directory)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let values = [segment("ad", 2, 8, duration: 10)]
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in values }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach() }
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await coordinator.waitForSynchronization()
        await beginPlaying(player, coordinator: coordinator, rate: 1.5)
        let positioned = await player.seek(to: CMTime(seconds: 3.25, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        coordinator.playbackStateChanged(allowed: true)
        for _ in 0..<20 { await Task.yield() }
        guard case .manual = coordinator.notice else { return XCTFail("Playing native seek must retain user position") }
        XCTAssertEqual(player.currentTime().seconds, 3.25, accuracy: 0.4)
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.05)
    }

    @MainActor
    func testActualPlayerNaturallyCrossesThreeFractionalIntervalsAndEachOffersUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = try await readyPlayer(in: directory)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let values = [segment("first", 0.251, 0.653, duration: 10),
                      segment("second", 1.017, 1.479, duration: 10),
                      segment("third", 1.823, 2.367, duration: 10)]
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in values }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach() }
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await coordinator.waitForSynchronization()
        let allSkipped = expectation(description: "Three natural boundary seeks")
        allSkipped.expectedFulfillmentCount = 3
        var skippedIDs: [String] = []
        let subscription = coordinator.$notice.sink { notice in
            if case .skipped(_, _, let interval) = notice {
                skippedIDs.append(interval.segments[0].id)
                allSkipped.fulfill()
            }
        }
        // Mirror the app's existing status subscription, including buffering
        // callbacks emitted while a managed seek is in flight.
        let status = PlayerTimeControlObservation(player: player) { _, _ in
            coordinator.playbackStateChanged(allowed: true)
        }
        await beginPlaying(player, coordinator: coordinator, rate: 1.5)
        await fulfillment(of: [allSkipped], timeout: 5)
        status.invalidate()
        subscription.cancel()
        XCTAssertEqual(skippedIDs, ["first", "second", "third"])
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.05)
        guard case .skipped(_, let from, let interval) = coordinator.notice else { return XCTFail("Final skip offers undo") }
        XCTAssertEqual(interval.segments[0].id, "third")
        XCTAssertGreaterThanOrEqual(from, 1.823)
        let undone = expectation(description: "Actual final interval undo completes")
        let undoSubscription = coordinator.$notice.sink { notice in
            if case .manual = notice { undone.fulfill() }
        }
        coordinator.performNoticeAction()
        await fulfillment(of: [undone], timeout: 5)
        undoSubscription.cancel()
        XCTAssertLessThan(player.currentTime().seconds, 2.367)
        guard case .manual = coordinator.notice else { return XCTFail("Undo is a manual pass") }
    }

    @MainActor
    func testSeekingBackToInitialPositionAfterPlayingDoesNotAutoSkip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = [segment("opening", 0, 20)]
        let repository = SponsorBlockRepository(directory: directory) { _, _ in values }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach() }
        let item = SponsorTestItem(asset: AVMutableComposition())
        let player = SponsorTestPlayer(playerItem: item)
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await coordinator.waitForSynchronization()
        player.position = 40
        player.playing = true
        coordinator.playbackStateChanged(allowed: true)
        player.position = 0
        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: item)
        coordinator.playbackStateChanged(allowed: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(player.seeks.isEmpty)
        guard case .manual = coordinator.notice else { return XCTFail("A later seek back to the start is a user seek") }
    }

    @MainActor
    private func readyPlayer(in directory: URL) async throws -> AVPlayer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("silent.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = 80_000
        buffer.floatChannelData![0].update(repeating: 0, count: 80_000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let ready = expectation(description: "Real AVPlayerItem ready")
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay || item.status == .failed { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "")
        XCTAssertEqual(item.duration.seconds, 10, accuracy: 0.05)
        return player
    }

    @MainActor
    func testSeekWhileSyncIsPendingRemainsManualWhenAnnotationsArrive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = try await readyPlayer(in: directory)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let gate = SponsorRequestGate()
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in try await gate.fetch() }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        defer { coordinator.detach() }
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await gate.waitForRequest()
        let positioned = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        await beginPlaying(player, coordinator: coordinator, rate: 1)
        await gate.succeed([segment("ad", 2, 8, duration: 10)])
        await coordinator.waitForSynchronization()
        guard case .manual = coordinator.notice else { return XCTFail("User's seek must remain manual after late data") }
        XCTAssertLessThan(player.currentTime().seconds, 4)
    }

    @MainActor
    func testDetachBeforeSeekTaskRunsCannotSeekReplacementItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = try await readyPlayer(in: directory)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let oldSegment = segment("old", 2, 8, duration: 10)
        let repository = SponsorBlockRepository(directory: directory.appendingPathComponent("cache")) { _, _ in [oldSegment] }
        let coordinator = SponsorBlockPlaybackCoordinator(sessionID: UUID(), repository: repository)
        coordinator.bind(player: player, item: item, key: key, offlineOnly: false, offlineDirectories: [],
                         configuration: SponsorConfiguration(enabled: true), playbackAllowed: true)
        await coordinator.waitForSynchronization()
        coordinator.skip(oldSegment)
        coordinator.detach()
        let replacement = AVPlayerItem(url: directory.appendingPathComponent("silent.caf"))
        player.replaceCurrentItem(with: replacement)
        let ready = expectation(description: "Replacement item ready")
        let observation = replacement.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay || item.status == .failed { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.05)
    }

    func testDelayedDiskReadCannotOverwriteFreshNetworkMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = SponsorSnapshot(schemaVersion: 1, key: key, fetchedAt: .distantPast, segments: [segment("old", 1, 2)])
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent(key.fileName))
        let gate = SponsorRequestGate()
        let repository = SponsorBlockRepository(directory: directory) { _, _ in try await gate.fetch() }
        let blocked = expectation(description: "File worker is blocked")
        let release = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await BlockingWorkQueue.files.run {
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        await fulfillment(of: [blocked], timeout: 5)
        let read = Task { await repository.cached(self.key) }
        let refresh = Task { try await repository.refresh(self.key) }
        await gate.waitForRequest()
        await gate.succeed([segment("new", 3, 4)])
        var current: SponsorSnapshot?
        for _ in 0..<100 {
            current = await repository.cachedInMemory(key)
            if current != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(current?.segments.first?.id, "new")
        release.signal()
        _ = try await blocker.value
        _ = await read.value
        let fresh = try await refresh.value
        let final = await repository.cached(key)
        XCTAssertEqual(final, fresh)
    }

    @MainActor
    private func waitForSync(_ coordinator: SponsorBlockPlaybackCoordinator) async {
        let ready = expectation(description: "Annotations applied")
        let subscription = coordinator.$syncState.sink { value in
            if value == .ready || value == .failed { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(coordinator.syncState, .ready)
    }

    @MainActor
    private func beginPlaying(_ player: AVPlayer, coordinator: SponsorBlockPlaybackCoordinator, rate: Float) async {
        let playing = expectation(description: "Real AVPlayer playing")
        let observation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            if player.timeControlStatus == .playing { playing.fulfill() }
        }
        player.playImmediately(atRate: rate)
        await fulfillment(of: [playing], timeout: 5)
        observation.invalidate()
        coordinator.playbackStateChanged(allowed: true)
    }
}

private actor SponsorRequestGate {
    private var continuation: CheckedContinuation<[SponsorSegment], Error>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func fetch() async throws -> [SponsorSegment] {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestWaiter?.resume(); requestWaiter = nil
        }
    }
    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func succeed(_ value: [SponsorSegment]) { continuation?.resume(returning: value); continuation = nil }
    func fail() { continuation?.resume(throwing: CocoaError(.fileReadUnknown)); continuation = nil }
}

private final class SponsorTestItem: AVPlayerItem {
    override var duration: CMTime { CMTime(seconds: 100, preferredTimescale: 600) }
}

private final class SponsorTestPlayer: AVPlayer {
    var position = 0.0
    var playing = false
    var seeks: [Double] = []
    override var timeControlStatus: AVPlayer.TimeControlStatus { playing ? .playing : .paused }
    override func currentTime() -> CMTime { CMTime(seconds: position, preferredTimescale: 600) }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping (Bool) -> Void) {
        seeks.append(time.seconds)
        position = time.seconds
        completionHandler(true)
    }
}
