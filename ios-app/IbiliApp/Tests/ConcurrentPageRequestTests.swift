import XCTest
@testable import Ibili

@MainActor
final class ConcurrentPageRequestTests: XCTestCase {
    func testOldSearchCannotOverwriteNewFiltersOrLoadingState() async throws {
        let entered = expectation(description: "old search entered")
        let finished = expectation(description: "old search returned")
        let gate = DispatchSemaphore(value: 0)
        let core = CoreClient { method, args in
            guard method == "search.video" else { throw URLError(.unsupportedURL) }
            let json = try JSONSerialization.jsonObject(with: Data(args.utf8)) as! [String: Any]
            let old = json["order"] as? String == nil
            if old {
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
                finished.fulfill()
            }
            return "{\"ok\":true,\"data\":{\"items\":[{\"aid\":\(old ? 1 : 2)}],\"num_results\":1,\"num_pages\":1}}"
        }
        let model = SearchViewModel(client: core)
        model.submit(query: "same query")
        await fulfillment(of: [entered], timeout: 2)
        model.order = .click
        model.resubmitSubmittedQuery()
        await settle { model.results.first?.id == "video-2" && !model.isLoading }
        gate.signal()
        await fulfillment(of: [finished], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.results.first?.id, "video-2")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorText)
    }

    func testCancelledHydrationDoesNotOverwriteNextMediaOrBecomeCachedSuccess() async throws {
        let oldEntered = expectation(description: "old relation blocked")
        let gate = DispatchSemaphore(value: 0)
        let core = CoreClient { method, args in
            let json = try JSONSerialization.jsonObject(with: Data(args.utf8)) as! [String: Any]
            switch method {
            case "session.snapshot":
                return #"{"ok":true,"data":{"logged_in":true,"mid":42,"expires_at_secs":0}}"#
            case "interaction.archive_relation":
                if (json["aid"] as? Int) == 1 {
                    oldEntered.fulfill()
                    guard gate.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
                }
                return #"{"ok":true,"data":{"liked":true,"disliked":false,"favorited":true,"attention":false,"coin_number":0}}"#
            case "interaction.fav_folders":
                return #"{"ok":true,"data":[{"id":42,"fid":42,"mid":42,"attr":1,"title":"folder","fav_state":1,"media_count":1}]}"#
            case "interaction.watchlater_aids":
                return #"{"ok":true,"data":[2]}"#
            default: throw URLError(.unsupportedURL)
            }
        }
        let service = VideoInteractionService(client: core)
        let old = Task { await service.hydrate(aid: 1, bvid: "a", ownerMid: nil) }
        await fulfillment(of: [oldEntered], timeout: 2)
        old.cancel()
        service.resetForNextItem()
        await service.hydrate(aid: 2, bvid: "b", ownerMid: nil)
        XCTAssertTrue(service.matchesHydratedState(aid: 2, bvid: "b"))
        gate.signal()
        await old.value
        XCTAssertTrue(service.matchesHydratedState(aid: 2, bvid: "b"))
        XCTAssertEqual(service.folders.map(\.folderId), [42])
        XCTAssertTrue(service.state.inWatchLater)
        XCTAssertFalse(service.isHydrating)
    }

    private func settle(_ condition: () -> Bool) async {
        // Bounded host scheduling allowance; network completion itself is controlled.
        for _ in 0..<2000 { if condition() { return }; await Task.yield() }
        XCTFail("expected response was not published")
    }
}
