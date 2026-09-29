import XCTest
@testable import Ibili

final class PerformanceRequestTests: XCTestCase {
    func testReadRequestsOverlapAndSnapshotDoesNotWaitForNetwork() async throws {
        let entered = expectation(description: "both reads entered")
        entered.expectedFulfillmentCount = 2
        let gate = DispatchSemaphore(value: 0)
        let core = CoreClient { method, _ in
            if method == "feed.home" {
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
                return #"{"ok":true,"data":{"items":[],"has_more":false,"next_idx":0}}"#
            }
            return #"{"ok":true,"data":{"logged_in":false,"mid":0,"expires_at_secs":0}}"#
        }
        let first = Task { try await core.perform { try $0.feedHome() } }
        let second = Task { try await core.perform { try $0.feedHome() } }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(core.sessionSnapshot().loggedIn)
        gate.signal(); gate.signal()
        _ = try await first.value
        _ = try await second.value
    }

    func testOldCredentialResultIsRejectedAndWritesStayOrderedAcrossReplacement() async throws {
        let oldEntered = expectation(description: "old write entered")
        let newAttempted = expectation(description: "new caller reached write")
        let gate = DispatchSemaphore(value: 0)
        let recorder = WriteRecorder()
        let core = CoreClient { method, args in
            guard method == "interaction.dislike" else { return #"{"ok":true,"data":{}}"# }
            let json = try JSONSerialization.jsonObject(with: Data(args.utf8)) as! [String: Any]
            if (json["aid"] as? Int) == 1 {
                recorder.append("old-start")
                oldEntered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
                recorder.append("old-end")
            } else { recorder.append("new-start") }
            return #"{"ok":true,"data":{}}"#
        }
        let first = Task { try await core.perform { try $0.archiveDislike(aid: 1) } }
        await fulfillment(of: [oldEntered], timeout: 2)
        core.logout()
        let second = Task {
            try await core.perform {
                newAttempted.fulfill()
                try $0.archiveDislike(aid: 2)
            }
        }
        await fulfillment(of: [newAttempted], timeout: 2)
        XCTAssertEqual(recorder.values, ["old-start"])
        gate.signal()
        do { try await first.value; XCTFail("old credentials were accepted") }
        catch is CancellationError { }
        try await second.value
        XCTAssertEqual(recorder.values, ["old-start", "old-end", "new-start"])
    }

    func testCancelledQueuedBlockingWorkDoesNotRun() async throws {
        let queue = BlockingWorkQueue(name: "test.blocking", concurrency: 1)
        let entered = expectation(description: "occupied")
        let gate = DispatchSemaphore(value: 0)
        let first = Task { try await queue.run { entered.fulfill(); _ = gate.wait(timeout: .now() + 3) } }
        await fulfillment(of: [entered], timeout: 2)
        let cancelled = Task { try await queue.run { XCTFail("cancelled work executed") } }
        cancelled.cancel()
        gate.signal()
        _ = try await first.value
        do { try await cancelled.value; XCTFail("cancellation not reported") }
        catch is CancellationError { }
    }

    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}

@MainActor
final class PlayUrlPrefetcherTests: XCTestCase {
    private final class Loader {
        var requests: [PlayUrlPrefetcher.Request] = []
        var continuations: [CheckedContinuation<PlayUrlDTO, Error>] = []
        func load(_ request: PlayUrlPrefetcher.Request) async throws -> PlayUrlDTO {
            requests.append(request)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func finish(_ index: Int) throws {
            let json = #"{"url":"https://example.invalid/media","format":"dash","stream_type":"dash","quality":80,"duration_ms":1000}"#
            continuations[index].resume(returning: try JSONDecoder().decode(PlayUrlDTO.self, from: Data(json.utf8)))
        }
    }

    private func item(_ aid: Int64 = 1) -> FeedItemDTO {
        FeedItemDTO(aid: aid, bvid: "BV1fk4y1E7r3", cid: aid * 10, title: "test", cover: "", author: "", durationSec: 1, play: 0, danmaku: 0)
    }

    private func value(_ prefetcher: PlayUrlPrefetcher, aid: Int64 = 1) async throws -> PlayUrlDTO {
        try await prefetcher.value(aid: aid, bvid: item(aid).bvid, cid: aid * 10, qn: 120,
                                  audioQn: 0, cdn: "auto", codecPreference: "auto")
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("expected state was not reached")
    }

    func testAbandonedPrefetchIsRejoinedWithoutDuplicateNetworkWork() async throws {
        let loader = Loader()
        let prefetcher = PlayUrlPrefetcher(load: { request, _, _ in try await loader.load(request) })
        prefetcher.prefetch(item: item(), qn: 120, audioQn: 0, cdn: "auto")
        await settle { loader.requests.count == 1 }
        prefetcher.retain(visibleKeys: [])
        let playback = Task { try await value(prefetcher) }
        await Task.yield()
        XCTAssertEqual(loader.requests.count, 1)
        try loader.finish(0)
        let result = try await playback.value
        XCTAssertEqual(result.quality, 80)
    }

    func testLatestVisiblePrefetchStartsAfterActualOldCompletion() async throws {
        let loader = Loader()
        let prefetcher = PlayUrlPrefetcher(load: { request, _, _ in try await loader.load(request) })
        prefetcher.prefetch(item: item(), qn: 120, audioQn: 0, cdn: "auto")
        await settle { loader.requests.count == 1 }
        prefetcher.prefetch(item: item(2), qn: 120, audioQn: 0, cdn: "auto")
        prefetcher.retain(visibleKeys: [2])
        XCTAssertEqual(loader.requests.count, 1)
        try loader.finish(0)
        await settle { loader.requests.count == 2 }
        XCTAssertEqual(loader.requests[1].aid, 2)
        try loader.finish(1)
    }

    func testCancelOneConsumerKeepsOtherAndSessionChangeRejectsOldResult() async throws {
        let loader = Loader()
        var generation = UUID()
        let prefetcher = PlayUrlPrefetcher(generation: { generation }, load: { request, _, _ in try await loader.load(request) })
        let first = Task { try await value(prefetcher) }
        let second = Task { try await value(prefetcher) }
        await settle { loader.requests.count == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("cancelled consumer returned") }
        catch is CancellationError { }
        generation = UUID()
        try loader.finish(0)
        do { _ = try await second.value; XCTFail("old session result returned") }
        catch is CancellationError { }
        let replacement = Task { try await value(prefetcher) }
        await settle { loader.requests.count == 2 }
        XCTAssertEqual(loader.requests[1].generation, generation)
        try loader.finish(1)
        _ = try await replacement.value
    }
}
