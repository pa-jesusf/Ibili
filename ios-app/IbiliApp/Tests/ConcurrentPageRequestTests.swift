import XCTest
@testable import Ibili

@MainActor
final class ConcurrentPageRequestTests: XCTestCase {
    func testFilterDraftIsLocalAndApplyRestartsSubmittedQueryWithVideoParameters() async throws {
        let category = SearchCategories.all.first { $0.id == "tech" }!
        let core = CoreClient { method, args in
            XCTAssertEqual(method, "search.video")
            let json = try JSONSerialization.jsonObject(with: Data(args.utf8)) as! [String: Any]
            let applying = json["order"] as? String == "click"
            XCTAssertEqual(json["keyword"] as? String, "original query")
            if applying {
                XCTAssertEqual(json["page"] as? Int, 1)
                XCTAssertEqual(json["duration"] as? Int, 4)
                XCTAssertEqual(json["tids"] as? Int, 188)
            }
            return "{\"ok\":true,\"data\":{\"items\":[{\"aid\":\(applying ? 99 : (json["page"] as? Int ?? 0))}],\"num_results\":60,\"num_pages\":3}}"
        }
        let model = SearchViewModel(client: core)
        model.submit(query: "original query")
        await settle { model.page == 1 && !model.isLoading }
        model.loadPage(2)
        await settle { model.page == 2 && !model.isLoading }
        var draft = model.filterSelection
        draft.order = .click
        draft.duration = .over60
        draft.category = category
        XCTAssertEqual(model.filterSelection, SearchFilterSelection(), "canceling a draft must leave live filters alone")
        XCTAssertEqual(model.page, 2)
        model.query = "unsubmitted editing text"
        XCTAssertTrue(model.applyFilters(draft))
        await settle { model.results.first?.id == "video-99" && !model.isLoading }
        XCTAssertEqual(model.page, 1)
        XCTAssertEqual(model.submittedQuery, "original query")
        XCTAssertEqual(model.filterSelection, draft)
    }

    func testApplyingUserAndArticleFiltersKeepsTheirSearchTypeAndParameters() async throws {
        for type in [SearchResultType.user, .article] {
            let core = CoreClient { method, args in
                let json = try JSONSerialization.jsonObject(with: Data(args.utf8)) as! [String: Any]
                switch method {
                case "search.video":
                    return #"{"ok":true,"data":{"items":[],"num_results":0,"num_pages":1}}"#
                case "search.user":
                    if json["order"] as? String == "fans" {
                        XCTAssertEqual(json["order_sort"] as? Int, 1)
                        XCTAssertEqual(json["user_type"] as? Int, 1)
                    }
                case "search.article":
                    if json["order"] as? String == "pubdate" {
                        XCTAssertEqual(json["category_id"] as? Int, 17)
                    }
                default:
                    XCTFail("unexpected search method: \(method)")
                }
                let filtered = json["order"] as? String == (type == .user ? "fans" : "pubdate")
                return "{\"ok\":true,\"data\":{\"items\":[],\"num_results\":\(filtered ? 99 : 0),\"num_pages\":1}}"
            }
            let model = SearchViewModel(client: core)
            model.submit(query: "query")
            await settle { model.page == 1 && !model.isLoading }
            model.selectedType = type
            await settle { model.page == 1 && !model.isLoading }
            var draft = model.filterSelection
            draft.userOrder = .fansAsc
            draft.userKind = .up
            draft.articleOrder = .pubdate
            draft.articleZone = .tech
            XCTAssertTrue(model.applyFilters(draft))
            await settle { model.totalResults == 99 && !model.isLoading }
            XCTAssertEqual(model.selectedType, type)
            XCTAssertEqual(model.submittedQuery, "query")
        }
    }

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
