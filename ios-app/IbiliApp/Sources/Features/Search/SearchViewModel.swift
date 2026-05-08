import Foundation
import SwiftUI

/// Drives the Search screen state machine: holds the current query,
/// tracks which `SearchResultType` tab is active, owns the paginated
/// list of paginated results, and exposes simple page navigation entry
/// points.
///
/// Implementation notes:
/// * `.video` and `.live` are implemented. Video keeps the full filter
///   surface; live ignores video-only filters.
/// * Pagination is explicit. Calling `submit` always restarts from
///   `page = 1`; users move with previous/next controls instead of
///   scroll-triggered infinite loading.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedType: SearchResultType = .video {
        didSet {
            guard oldValue != selectedType else { return }
            guard hasSubmittedQuery, query == submittedQuery, selectedType.isImplemented else { return }
            results = []
            page = 0
            totalResults = 0
            hasMore = true
            errorText = nil
            Task { await fetchPage(1) }
        }
    }
    @Published var selectedCategory: SearchCategory? = nil
    @Published var order: SearchOrder = .totalrank
    @Published var durationFilter: SearchDuration = .any

    @Published private(set) var results: [SearchResultItem] = []
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
        guard selectedType.isImplemented else {
            isLoading = false
            hasMore = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        let queryCopy = query
        let typeCopy = selectedType

        do {
            let pageData: SearchPageResult
            switch typeCopy {
            case .video:
                let order = order == .totalrank ? nil : order.rawValue
                let durationParam = durationFilter == .any ? nil : durationFilter.rawValue
                let tids = selectedCategory?.tids
                pageData = try await Task.detached(priority: .userInitiated) { [client] in
                    let page = try client.searchVideo(
                        keyword: queryCopy,
                        page: targetPage,
                        order: order,
                        duration: durationParam,
                        tids: tids
                    )
                    return SearchPageResult(
                        items: page.items.map(SearchResultItem.video),
                        numResults: page.numResults,
                        numPages: page.numPages
                    )
                }.value
            case .live:
                pageData = try await Task.detached(priority: .userInitiated) { [client] in
                    let page = try client.searchLive(keyword: queryCopy, page: targetPage)
                    return SearchPageResult(
                        items: page.items.map(SearchResultItem.live),
                        numResults: page.numResults,
                        numPages: page.numPages
                    )
                }.value
            case .bangumi, .movie, .user, .article:
                return
            }
            // Guard against late callbacks for a stale query.
            guard queryCopy == self.query, typeCopy == self.selectedType else { return }
            self.page = targetPage
            self.results = pageData.items
            self.totalResults = pageData.numResults
            self.hasMore = targetPage < pageData.numPages && !pageData.items.isEmpty
        } catch {
            errorText = (error as NSError).localizedDescription
            hasMore = false
        }
    }
}

enum SearchResultItem: Identifiable, Hashable {
    case video(SearchVideoItemDTO)
    case live(SearchLiveItemDTO)

    var id: String {
        switch self {
        case .video(let item):
            return "video-\(item.id)"
        case .live(let item):
            return "live-\(item.id)"
        }
    }
}

private struct SearchPageResult {
    let items: [SearchResultItem]
    let numResults: Int64
    let numPages: Int64
}
