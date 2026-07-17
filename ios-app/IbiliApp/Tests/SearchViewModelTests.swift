import XCTest
@testable import Ibili

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testCategorySubmitSynchronizesQueryAndFilter() {
        let vm = SearchViewModel(automaticallyLoads: false)
        let category = SearchCategories.all.first!

        XCTAssertTrue(vm.submit(query: category.name, category: category))

        XCTAssertEqual(vm.query, category.name)
        XCTAssertEqual(vm.submittedQuery, category.name)
        XCTAssertEqual(vm.selectedType, .video)
        XCTAssertEqual(vm.selectedCategory, category)
        XCTAssertTrue(vm.hasActiveSubmittedQuery)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testManualSubmitClearsCategoryButKeepsResultsMode() {
        let vm = SearchViewModel(automaticallyLoads: false)
        let category = SearchCategories.all.first!

        XCTAssertTrue(vm.submit(query: category.name, category: category))
        vm.query = "  手动关键词  "
        XCTAssertTrue(vm.submit())

        XCTAssertEqual(vm.query, "手动关键词")
        XCTAssertEqual(vm.submittedQuery, "手动关键词")
        XCTAssertNil(vm.selectedCategory)
        XCTAssertTrue(vm.hasActiveSubmittedQuery)
    }

    func testClearingQueryReturnsToLandingAndResetsFilters() {
        let vm = SearchViewModel(automaticallyLoads: false)
        let category = SearchCategories.all.first!

        XCTAssertTrue(vm.submit(query: category.name, category: category))
        vm.order = .click
        vm.durationFilter = .over60
        vm.handleQueryTextChanged("")

        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.submittedQuery, "")
        XCTAssertFalse(vm.hasActiveSubmittedQuery)
        XCTAssertNil(vm.selectedCategory)
        XCTAssertEqual(vm.selectedType, .video)
        XCTAssertEqual(vm.order, .totalrank)
        XCTAssertEqual(vm.durationFilter, .any)
    }

    func testEmptySubmitDoesNotEnterResultsMode() {
        let vm = SearchViewModel(automaticallyLoads: false)

        vm.query = "   "

        XCTAssertFalse(vm.submit())
        XCTAssertEqual(vm.query, "   ")
        XCTAssertEqual(vm.submittedQuery, "")
        XCTAssertFalse(vm.hasActiveSubmittedQuery)
    }
}

final class RootSearchStateTests: XCTestCase {
    func testPresentationActivatesEditingWithoutEnteringResults() {
        var state = RootSearchState()

        state.send(.presentationChanged(true))

        XCTAssertEqual(state.phase, .editing)
        XCTAssertTrue(state.isPresented)
    }

    func testSubmitKeepsSearchPresentedWhileShowingResults() {
        var state = RootSearchState()
        state.send(.presentationChanged(true))

        state.send(.submitted)

        XCTAssertEqual(state.phase, .results)
        XCTAssertTrue(state.isPresented)
    }

    func testClearingQueryReturnsToLandingWithoutDismissingSearch() {
        var state = RootSearchState()
        state.send(.presentationChanged(true))
        state.send(.submitted)

        state.send(.queryCleared)

        XCTAssertEqual(state.phase, .editing)
        XCTAssertTrue(state.isPresented)
    }

    func testSystemDismissIsTheOnlyEventThatEndsSearchSession() {
        var state = RootSearchState()
        state.send(.presentationChanged(true))
        state.send(.submitted)
        state.send(.queryCleared)

        state.send(.presentationChanged(false))

        XCTAssertEqual(state.phase, .inactive)
        XCTAssertFalse(state.isPresented)
    }
}
