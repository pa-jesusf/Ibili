import Foundation
import SwiftUI

/// Drives the Search screen state machine: holds the current query,
/// tracks which `SearchResultType` tab is active, owns the paginated
/// list of paginated results, and exposes simple page navigation entry
/// points.
///
/// Implementation notes:
/// * All visible tabs are implemented. Video keeps the full filter surface;
///   user/article expose their upstream filters, while live/PGC have no extra
///   search filters.
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
    @Published var userOrder: SearchUserOrder = .defaultOrder
    @Published var userKind: SearchUserKind = .all
    @Published var articleOrder: SearchArticleOrder = .totalrank
    @Published var articleZone: SearchArticleZone = .all

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

    func hideVideo(aid: Int64) {
        guard aid > 0 else { return }
        results.removeAll {
            if case .video(let video) = $0 {
                return video.aid == aid
            }
            return false
        }
    }

    func hideVideos(fromOwner mid: Int64) {
        guard mid > 0 else { return }
        results.removeAll {
            if case .video(let video) = $0 {
                return video.ownerMID == mid
            }
            return false
        }
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
        let videoOrderCopy = order
        let durationCopy = durationFilter
        let categoryCopy = selectedCategory
        let userOrderCopy = userOrder
        let userKindCopy = userKind
        let articleOrderCopy = articleOrder
        let articleZoneCopy = articleZone

        do {
            let pageData: SearchPageResult
            switch typeCopy {
            case .video:
                let order = videoOrderCopy == .totalrank ? nil : videoOrderCopy.rawValue
                let durationParam = durationCopy == .any ? nil : durationCopy.rawValue
                let tids = categoryCopy?.tids
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
            case .user:
                pageData = try await Task.detached(priority: .userInitiated) { [client] in
                    let page = try client.searchUser(
                        keyword: queryCopy,
                        page: targetPage,
                        order: userOrderCopy.order,
                        orderSort: userOrderCopy.orderSort,
                        userType: userKindCopy.parameter
                    )
                    return SearchPageResult(
                        items: page.items.map(SearchResultItem.user),
                        numResults: page.numResults,
                        numPages: page.numPages
                    )
                }.value
            case .article:
                pageData = try await Task.detached(priority: .userInitiated) { [client] in
                    let page = try client.searchArticle(
                        keyword: queryCopy,
                        page: targetPage,
                        order: articleOrderCopy.rawValue,
                        categoryID: articleZoneCopy.categoryID
                    )
                    return SearchPageResult(
                        items: page.items.map(SearchResultItem.article),
                        numResults: page.numResults,
                        numPages: page.numPages
                    )
                }.value
            case .bangumi, .movie:
                let searchType = typeCopy == .bangumi ? "media_bangumi" : "media_ft"
                pageData = try await Task.detached(priority: .userInitiated) { [client] in
                    let page = try client.searchPgc(
                        keyword: queryCopy,
                        page: targetPage,
                        searchType: searchType
                    )
                    return SearchPageResult(
                        items: page.items.map(SearchResultItem.pgc),
                        numResults: page.numResults,
                        numPages: page.numPages
                    )
                }.value
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
    case user(SearchUserItemDTO)
    case article(SearchArticleItemDTO)
    case pgc(SearchPgcItemDTO)

    var id: String {
        switch self {
        case .video(let item):
            return "video-\(item.id)"
        case .live(let item):
            return "live-\(item.id)"
        case .user(let item):
            return "user-\(item.id)"
        case .article(let item):
            return "article-\(item.id)"
        case .pgc(let item):
            return "pgc-\(item.id)"
        }
    }
}

private struct SearchPageResult {
    let items: [SearchResultItem]
    let numResults: Int64
    let numPages: Int64
}
