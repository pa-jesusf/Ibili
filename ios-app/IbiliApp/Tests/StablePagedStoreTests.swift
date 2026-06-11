import XCTest
@testable import Ibili

@MainActor
final class StablePagedStoreTests: XCTestCase {
    func testAppendFiltersDuplicatesWithoutReorderingExistingItems() {
        let store = StablePagedStore<Int, Int> { $0 }
        let generation = store.reset()

        XCTAssertEqual(store.append([1, 2, 3], generation: generation), [1, 2, 3])
        XCTAssertEqual(store.append([2, 4, 3, 5], generation: generation), [4, 5])
        XCTAssertEqual(store.items, [1, 2, 3, 4, 5])
    }

    func testReplaceResetsLoadedIdentitySet() {
        let store = StablePagedStore<Int, Int> { $0 }
        var generation = store.reset()
        _ = store.append([1, 2, 3], generation: generation)

        generation = store.reset()
        XCTAssertEqual(store.replace(with: [2, 4], generation: generation), [2, 4])
        XCTAssertEqual(store.items, [2, 4])
    }

    func testPreservingResetKeepsVisibleItemsUntilReplacement() {
        let store = StablePagedStore<Int, Int> { $0 }
        var generation = store.reset()
        _ = store.append([1, 2, 3], generation: generation)

        generation = store.reset(preservingItems: true)
        XCTAssertEqual(store.items, [1, 2, 3])

        XCTAssertEqual(store.replace(with: [2, 4], generation: generation), [2, 4])
        XCTAssertEqual(store.items, [2, 4])
    }

    func testStaleGenerationCannotMutateItems() {
        let store = StablePagedStore<Int, Int> { $0 }
        let oldGeneration = store.reset()
        let newGeneration = store.reset()

        XCTAssertTrue(store.append([1, 2], generation: oldGeneration).isEmpty)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.append([3], generation: newGeneration), [3])
        XCTAssertEqual(store.items, [3])
    }

    func testRemoveDropsIdentitySoItemCanReturnAfterRefresh() {
        let store = StablePagedStore<Int, Int> { $0 }
        let generation = store.reset()
        _ = store.append([1, 2, 3], generation: generation)

        store.remove { $0 == 2 }
        XCTAssertEqual(store.items, [1, 3])
        XCTAssertEqual(store.append([2], generation: generation), [2])
        XCTAssertEqual(store.items, [1, 3, 2])
    }
}
