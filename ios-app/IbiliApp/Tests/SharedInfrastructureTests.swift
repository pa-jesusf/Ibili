import XCTest
@testable import Ibili

final class SharedInfrastructureTests: XCTestCase {
    private struct Row: Identifiable, Hashable { let id: Int; var text: String }

    func testCollectionVersionSkipsProducerAndReportsOnlyChangedRows() {
        var state = CollectionItemState<Row>()
        let rows = [Row(id: 1, text: "a"), Row(id: 2, text: "b")]
        XCTAssertTrue(state.update(rows, version: 1).structure)
        func forbidden() -> [Row] { XCTFail("unchanged revision evaluated all rows"); return [] }
        XCTAssertTrue(state.update(forbidden(), version: 1).changed.isEmpty)
        XCTAssertTrue(state.update(rows).changed.isEmpty)
        var changed = rows
        changed[1].text = "new"
        let delta = state.update(changed)
        XCTAssertFalse(delta.structure)
        XCTAssertEqual(delta.changed, [2])
        XCTAssertTrue(state.update([changed[1], changed[0]]).structure)
        XCTAssertFalse(state.update([changed[1], changed[0], changed[0]]).structure)
        XCTAssertEqual(state.orderedIDs, [2, 1])
    }

    func testCollectionOuterEdgesFollowDeduplicatedOrderAcrossPagingAndRemoval() {
        var state = CollectionItemState<Row>()
        let rows = (1...4).map { Row(id: $0, text: "row-\($0)") }
        _ = state.update(Array(rows.prefix(2)), reconfigureEdges: true)
        let duplicate = state.update([rows[0], rows[1], rows[0]], reconfigureEdges: true)
        XCTAssertFalse(duplicate.structure)
        XCTAssertTrue(duplicate.changed.isEmpty)
        XCTAssertEqual(state.orderedIDs, [1, 2])

        let appended = state.update([rows[0], rows[1], rows[2], rows[1]], reconfigureEdges: true)
        XCTAssertEqual(state.orderedIDs, [1, 2, 3])
        XCTAssertTrue(Set([2, 3]).isSubset(of: Set(appended.changed)), "old last row must lose bottom corners")
        let prepended = state.update([rows[3], rows[0], rows[1], rows[2]], reconfigureEdges: true)
        XCTAssertTrue(Set([1, 4]).isSubset(of: Set(prepended.changed)), "old first row must lose top corners")
        let trimmed = state.update(Array(rows.prefix(2)), reconfigureEdges: true)
        XCTAssertEqual(Set(trimmed.changed), [1, 2])
        let single = state.update([rows[1]], reconfigureEdges: true)
        XCTAssertEqual(state.orderedIDs, [2])
        XCTAssertEqual(single.changed, [2], "the surviving row must gain all four corners")
        let empty = state.update([], reconfigureEdges: true)
        XCTAssertTrue(state.orderedIDs.isEmpty)
        XCTAssertTrue(empty.changed.isEmpty)
    }

    func testCollectionEdgeStyleKeepsUnchangedVersionFastPath() {
        var state = CollectionItemState<Row>()
        _ = state.update([Row(id: 1, text: "a")], version: 1, reconfigureEdges: true)
        func forbidden() -> [Row] { XCTFail("unchanged revision evaluated rows"); return [] }
        let delta = state.update(forbidden(), version: 1, reconfigureEdges: true)
        XCTAssertFalse(delta.structure)
        XCTAssertTrue(delta.changed.isEmpty)
    }

    func testCoalescedCollectionUpdatesKeepPreviousEdgeInvalidations() {
        var state = CollectionItemState<Row>()
        let rows = (1...5).map { Row(id: $0, text: "row-\($0)") }
        _ = state.update(Array(rows.prefix(2)), reconfigureEdges: true)
        _ = state.update(Array(rows.prefix(3)), reconfigureEdges: true)
        _ = state.update(Array(rows.prefix(4)), reconfigureEdges: true)
        let latest = state.update(rows, reconfigureEdges: true)
        // If intermediate pending snapshots are replaced, former edge rows
        // still need to lose their corners in the final committed snapshot.
        XCTAssertTrue(Set([2, 3, 4]).isSubset(of: Set(latest.changed)))
    }

    func testImageDiskIndexAccountsOverwriteClearAndRestartWithoutRescanning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageDiskCache(directory: root)
        let first = URL(string: "https://example.invalid/1")!
        let second = URL(string: "https://example.invalid/2")!
        cache.write(first, data: Data(repeating: 1, count: 20))
        cache.write(second, data: Data(repeating: 2, count: 30))
        XCTAssertEqual(cache.currentBytes(), 50)
        cache.write(first, data: Data(repeating: 3, count: 5))
        XCTAssertEqual(cache.currentBytes(), 35)
        XCTAssertEqual(cache.indexScanCount, 1)
        XCTAssertEqual(cache.read(first), Data(repeating: 3, count: 5))
        XCTAssertEqual(ImageDiskCache(directory: root).currentBytes(), 35)
        cache.clearAll()
        XCTAssertEqual(cache.currentBytes(), 0)
        cache.write(first, data: Data([7]))
        XCTAssertEqual(cache.currentBytes(), 1)
        XCTAssertEqual(cache.indexScanCount, 1)
    }

    func testLiveParserKeepsLatestBatchAndRejectsInvalidPacketSizes() throws {
        var parser = LiveDanmakuParser(roomID: 1, selfMID: 8)
        let json = (1...1001).map { #"{"cmd":"DANMU_MSG","info":[[],"message-\#($0)",[8,"user"]]}"# }.joined(separator: "\0")
        let batch = parser.decode(Data(json.utf8), json: true)
        XCTAssertEqual(batch.events.count, 1000)
        XCTAssertEqual(batch.events.first?.message.text, "message-2")
        XCTAssertEqual(batch.events.last?.message.text, "message-1001")
        XCTAssertTrue(batch.events.allSatisfy { $0.item.isSelf && $0.message.isSelf })
        XCTAssertTrue(parser.decode(Data(repeating: 0, count: 16)).events.isEmpty)
    }

    func testLiveRingEvictionDedupAndOverlappingHistoryOrder() {
        func message(_ id: String) -> LiveDanmakuMessageDTO {
            LiveDanmakuMessageDTO(id: id, uid: 1, name: "", text: id, isSelf: false)
        }
        var ring = LiveMessageBuffer(capacity: 3)
        ring.append(["a", "b", "c", "d"].map(message))
        XCTAssertEqual(ring.messages.map(\.id), ["b", "c", "d"])
        XCTAssertFalse(ring.append([message("c")]))
        XCTAssertTrue(ring.append([message("a")]))
        XCTAssertEqual(ring.messages.map(\.id), ["c", "d", "a"])
        var overlap = LiveMessageBuffer(capacity: 10)
        overlap.append(["b", "d"].map(message))
        overlap.prependHistory(["a", "b", "c"].map(message))
        XCTAssertEqual(overlap.messages.map(\.id), ["a", "b", "c", "d"])
    }

    func testOfflineIndexPreservesAllHistoricalDirectoriesAndUsesNewestMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (title, date) in [("old", "2026-01-01T00:00:00Z"), ("new", "2026-02-01T00:00:00Z")] {
            let directory = root.appendingPathComponent(title + "-same-id")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let json = #"{"id":"same-id","sourceType":"ugc","aid":1,"bvid":"BV1fk4y1E7r3","cid":10,"epID":0,"seasonID":0,"title":"\#(title)","author":"","cover":"","durationSec":10,"qn":80,"qnLabel":"","audioQn":0,"audioQnLabel":"","videoFileName":"video.mp4","danmakuFileName":"danmaku.json","createdAt":"\#(date)","updatedAt":"\#(date)","status":"completed","progress":1,"danmakuStatus":"completed"}"#
            try Data(json.utf8).write(to: directory.appendingPathComponent("metadata.json"))
            try Data([1]).write(to: directory.appendingPathComponent("video.mp4"))
        }
        let records = try OfflineLibraryIndex.scan(root)
        let record = try XCTUnwrap(records["same-id"])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.metadata.title, "new")
        XCTAssertEqual(record.allDirectories.count, 2)
        XCTAssertNotNil(record.videoURL)
        for directory in record.allDirectories { try FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try OfflineLibraryIndex.scan(root).isEmpty)
    }
}

@MainActor
final class VideoDetailRepositoryTests: XCTestCase {
    private func view(_ title: String) throws -> VideoViewDTO {
        let json = #"{"aid":1,"bvid":"BV1fk4y1E7r3","cid":10,"title":"\#(title)","cover":"","desc":"","desc_v2":[],"duration_sec":10,"pubdate":0,"ctime":0,"videos":1,"stat":{"view":0,"danmaku":0,"reply":0,"favorite":0,"coin":0,"share":0,"like":0},"owner":{"mid":1,"name":"","face":""},"pages":[],"tags":[],"honor":[],"redirect_url":""}"#
        return try JSONDecoder().decode(VideoViewDTO.self, from: Data(json.utf8))
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("expected IO boundary not reached")
    }
    func testAVLateResultCannotReplaceNewerBVRefreshAndAliasesReuseCache() async throws {
        var pending: [CheckedContinuation<VideoViewDTO, Error>] = []
        let repository = VideoDetailRepository(load: { _, _ in try await withCheckedThrowingContinuation { pending.append($0) } })
        let old = Task { try await repository.detail(aid: 1, bvid: "") }
        await settle { pending.count == 1 }
        let fresh = Task { try await repository.detail(aid: 1, bvid: "BV1fk4y1E7r3", force: true) }
        await settle { pending.count == 2 }
        pending[1].resume(returning: try view("new"))
        _ = try await fresh.value
        pending[0].resume(returning: try view("old"))
        do { _ = try await old.value; XCTFail("late alias accepted") } catch is CancellationError { }
        let cached = try await repository.detail(aid: 1, bvid: "")
        XCTAssertEqual(cached.title, "new")
        XCTAssertEqual(pending.count, 2)
        do { _ = try await repository.detail(aid: 0, bvid: ""); XCTFail("missing ID selected unrelated cached video") }
        catch let error as CoreError { XCTAssertEqual(error.category, "invalid_argument") }
    }

    func testSessionChangeRejectsLateResultAndFailureIsRetryable() async throws {
        var generation = UUID()
        var pending: [CheckedContinuation<VideoViewDTO, Error>] = []
        let repository = VideoDetailRepository(generation: { generation }, load: { _, _ in
            try await withCheckedThrowingContinuation { pending.append($0) }
        })
        let old = Task { try await repository.detail(aid: 1, bvid: "") }
        await settle { pending.count == 1 }
        generation = UUID()
        pending[0].resume(returning: try view("old"))
        do { _ = try await old.value; XCTFail("accepted old credentials") } catch is CancellationError { }
        let failed = Task { try await repository.detail(aid: 1, bvid: "") }
        await settle { pending.count == 2 }
        pending[1].resume(throwing: URLError(.notConnectedToInternet))
        do { _ = try await failed.value; XCTFail("failure swallowed") } catch { }
        let retry = Task { try await repository.detail(aid: 1, bvid: "") }
        await settle { pending.count == 3 }
        pending[2].resume(returning: try view("new"))
        let result = try await retry.value
        XCTAssertEqual(result.title, "new")
    }

    func testRefreshFailureDoesNotResurrectSupersededAliasResult() async throws {
        var pending: [CheckedContinuation<VideoViewDTO, Error>] = []
        let repository = VideoDetailRepository(load: { _, _ in try await withCheckedThrowingContinuation { pending.append($0) } })
        let old = Task { try await repository.detail(aid: 1, bvid: "") }
        await settle { pending.count == 1 }
        let fresh = Task { try await repository.detail(aid: 1, bvid: "BV1fk4y1E7r3", force: true) }
        await settle { pending.count == 2 }
        pending[1].resume(returning: try view("new"))
        _ = try await fresh.value
        let failed = Task { try await repository.detail(aid: 1, bvid: "BV1fk4y1E7r3", force: true) }
        await settle { pending.count == 3 }
        pending[0].resume(returning: try view("old"))
        do { _ = try await old.value; XCTFail("superseded alias resurrected") } catch is CancellationError { }
        pending[2].resume(throwing: URLError(.notConnectedToInternet))
        do { _ = try await failed.value; XCTFail("failure swallowed") } catch { }
        let retry = Task { try await repository.detail(aid: 1, bvid: "") }
        await settle { pending.count == 4 }
        pending[3].resume(returning: try view("retry"))
        let result = try await retry.value
        XCTAssertEqual(result.title, "retry")
    }
}
