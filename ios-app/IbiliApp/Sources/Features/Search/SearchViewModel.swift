import Foundation
import SwiftUI

/// Drives the Search screen state machine: holds the current query,
/// tracks which `SearchResultType` tab is active, owns the paginated
/// list of video results, and exposes simple page navigation entry
/// points.
///
/// Implementation notes:
/// * Only `.video` results are fetched; other tabs flip the UI state
///   but produce zero results since the upstream endpoints aren't
///   wired yet.
/// * Pagination is explicit. Calling `submit` always restarts from
///   `page = 1`; users move with previous/next controls instead of
///   scroll-triggered infinite loading.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedType: SearchResultType = .video
    @Published var selectedCategory: SearchCategory? = nil
    @Published var order: SearchOrder = .totalrank
    @Published var durationFilter: SearchDuration = .any

    @Published private(set) var results: [SearchVideoItemDTO] = []
    @Published private(set) var page: Int64 = 0
    @Published private(set) var hasMore: Bool = false
    @Published private(set) var totalResults: Int64 = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorText: String? = nil

    /// The exact query string that produced `results`. Distinct from
    /// `query` so the UI can hide stale results as soon as the user
    /// starts editing the search field; we only consider results
    /// "current" when `query == submittedQuery`.
    @Published private(set) var submittedQuery: String = ""

    /// `true` once the user has triggered at least one search since the
    /// view appeared. Drives the landing → results swap.
    @Published private(set) var hasSubmittedQuery: Bool = false

    private let client: CoreClient

    init(client: CoreClient = .shared) {
        self.client = client
    }

    /// Run a fresh search using the current query + filter state.
    /// Empty / whitespace queries are ignored.
    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        submittedQuery = trimmed
        hasSubmittedQuery = true
        results = []
        page = 0
        totalResults = 0
        hasMore = true
        errorText = nil
        Task { await fetchPage(1) }
    }

    /// Fill the search box with the given query and immediately fire a
    /// new search.
    func submit(query: String, category: SearchCategory? = nil) {
        self.query = query
        if let category {
            selectedCategory = category
        }
        submit()
    }

    func loadNextPage() {
        guard hasMore, !isLoading else { return }
        Task { await fetchPage(page + 1) }
    }

    func loadPreviousPage() {
        guard page > 1, !isLoading else { return }
        Task { await fetchPage(page - 1) }
    }

    func loadPage(_ targetPage: Int64) {
        guard targetPage >= 1, targetPage != page, !isLoading else { return }
        Task { await fetchPage(targetPage) }
    }

    /// Clear results and return to the landing state. Used when the
    /// user dismisses the search field via the system Cancel button.
    func reset() {
        query = ""
        submittedQuery = ""
        results = []
        page = 0
        hasMore = false
        totalResults = 0
        errorText = nil
        hasSubmittedQuery = false
    }

    // MARK: - Private

    private func fetchPage(_ targetPage: Int64) async {
        // Only video search is implemented for now. Other tabs simply
        // surface an empty state with no error.
        guard selectedType == .video else {
            isLoading = false
            hasMore = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        let order = order == .totalrank ? nil : order.rawValue
        let durationParam = durationFilter == .any ? nil : durationFilter.rawValue
        let tids = selectedCategory?.tids
        let queryCopy = query

        do {
            let page = try await Task.detached(priority: .userInitiated) { [client] in
                try client.searchVideo(
                    keyword: queryCopy,
                    page: targetPage,
                    order: order,
                    duration: durationParam,
                    tids: tids
                )
            }.value
            // Guard against late callbacks for a stale query.
            guard queryCopy == self.query else { return }
            self.page = targetPage
            self.results = page.items
            self.totalResults = page.numResults
            self.hasMore = targetPage < page.numPages && !page.items.isEmpty
        } catch {
            errorText = (error as NSError).localizedDescription
            hasMore = false
        }
    }
}
