import XCTest
import Combine
import SwiftUI
import UIKit
@testable import Ibili

@MainActor
final class SearchResultSelectionTests: XCTestCase {
    func testNativeSelectionOpensSearchResultsWithTheirOriginalIdentifiers() async throws {
        let cases: [(SearchResultType, String, String)] = [
            (.video, "search.video", #"{"aid":101,"bvid":"BV1fk4y1E7r3","cid":303,"title":"视频","author":"UP","owner_mid":7}"#),
            (.live, "search.live", #"{"room_id":202,"uid":7,"title":"直播","cover":"","uname":"主播","face":"","online":9,"area_name":"游戏"}"#),
            (.user, "search.user", #"{"mid":7,"uname":"用户","face":"","sign":"简介","fans":9,"videos":2,"level":5,"is_live":false,"room_id":0,"official_desc":""}"#),
            (.article, "search.article", #"{"id":404,"title":"专栏","desc":"简介","cover":"","mid":7,"category_name":"科技","view":9,"like":2,"reply":1,"pub_time":0}"#),
        ]
        for (type, method, payload) in cases {
            let core = CoreClient { requested, _ in
                let items = requested == method ? payload : ""
                return "{\"ok\":true,\"data\":{\"items\":[\(items)],\"num_results\":1,\"num_pages\":1}}"
            }
            let vm = SearchViewModel(client: core)
            let loaded = expectation(description: "\(type) results loaded")
            let subscription = vm.$results.filter { !$0.isEmpty }.prefix(1).sink { _ in loaded.fulfill() }
            vm.submit(query: "query")
            vm.selectedType = type
            await fulfillment(of: [loaded], timeout: 2)
            withExtendedLifetime(subscription) {}

            var opened: [RootContentRoute] = []
            let content = SearchResultsView(vm: vm)
                .environmentObject(AppSettings())
                .environmentObject(DeepLinkRouter())
                .environment(\.rootContentNavigation, RootContentNavigationActions(open: { opened.append($0) }))
            let host = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.isHidden = false
            defer {
                window.rootViewController = nil
                window.isHidden = true
            }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            // Let SwiftUI install the representable and the diffable snapshot.
            await Task.yield()
            let ready = expectation(description: "\(type) result cell displayed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 1)
            host.view.layoutIfNeeded()

            let source = try XCTUnwrap(findSource(in: host))
            let collection = try XCTUnwrap(source.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collection.layoutIfNeeded()
            let indexPath = try XCTUnwrap(collection.indexPathsForVisibleItems.first {
                (collection.cellForItem(at: $0)?.bounds.height ?? 0) > 80
            })
            let cell = try XCTUnwrap(collection.cellForItem(at: indexPath))
            for point in [CGPoint(x: cell.bounds.midX, y: 12),
                          CGPoint(x: cell.bounds.midX, y: cell.bounds.midY),
                          CGPoint(x: 12, y: cell.bounds.maxY - 12)] {
                let hit = try XCTUnwrap(window.hitTest(cell.convert(point, to: window), with: nil))
                XCTAssertTrue(hit === cell || hit.isDescendant(of: cell), "\(type): entire card must stay reachable")
            }
            // Exercise the real collection delegate and the SearchResultsView
            // callback; an outer SwiftUI-only Button never reaches this route.
            collection.delegate?.collectionView?(collection, didSelectItemAt: indexPath)
            XCTAssertEqual(opened.count, 1, "\(type): one selection must open one destination")
            let route = try XCTUnwrap(opened.first)
            switch (type, route) {
            case (.video, .player(let player)):
                XCTAssertEqual(player.item.aid, 101)
                XCTAssertEqual(player.item.bvid, "BV1fk4y1E7r3")
                XCTAssertEqual(player.item.cid, 303)
                XCTAssertEqual(player.item.ownerMID, 7)
            case (.live, .live(let live)):
                XCTAssertEqual(live.roomID, 202)
            case (.user, .userSpace(let mid)):
                XCTAssertEqual(mid, 7)
            case (.article, .article(let id, let kind)):
                XCTAssertEqual(id, "404")
                XCTAssertEqual(kind, "read")
            default:
                XCTFail("Unexpected route for \(type): \(route)")
            }
        }
    }

    private func findSource(in controller: UIViewController) -> VirtualizedCollectionViewController<SearchResultItem>? {
        if let source = controller as? VirtualizedCollectionViewController<SearchResultItem> { return source }
        return controller.children.lazy.compactMap { self.findSource(in: $0) }.first
    }
}
