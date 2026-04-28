import Foundation

/// Minimal Range-aware HTTP fetcher that:
/// * always injects Bilibili's required UA + Referer
/// * uses a `default` URLSession (so iOS keeps it alive briefly when the
///   app drops to background, which combined with the `audio` background
///   mode keeps lock-screen audio playing without stalling)
/// * exposes a "race multiple URLs in parallel, take the first one whose
///   *Range probe* succeeds" primitive, mirroring the previous AVURLAsset
///   race so the new HLS proxy keeps the same CDN-selection guarantees.
final class ProxyURLLoader: @unchecked Sendable {
    static let shared = ProxyURLLoader()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = BiliHTTP.headers
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: cfg)
    }

    struct RangeResponse {
        let data: Data
        let totalBytes: Int64?     // total resource size if Content-Range was present
        let statusCode: Int
    }

    /// Fetch `range` (inclusive) from `url` and return the body bytes.
    /// `range == nil` requests the entire resource.
    func fetch(url: URL, range: ClosedRange<UInt64>? = nil) async throws -> RangeResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in BiliHTTP.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let range {
            req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyLoaderError.unexpectedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProxyLoaderError.httpStatus(http.statusCode, host: url.host ?? "?")
        }
        let total = parseContentRangeTotal(http.value(forHTTPHeaderField: "Content-Range"))
        return RangeResponse(data: data, totalBytes: total, statusCode: http.statusCode)
    }

    /// Race a Range probe across `urls`. Returns the URL of the first one
    /// that succeeds, plus the probed bytes and per-candidate trace lines.
    func raceProbe(urls: [URL], range: ClosedRange<UInt64>) async throws -> ProbeRaceOutcome {
        precondition(!urls.isEmpty, "no candidates")
        struct Outcome: Sendable {
            let url: URL
            let elapsedMs: Int
            let result: Result<Data, Error>
        }
        let raceStart = CFAbsoluteTimeGetCurrent()
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    let start = CFAbsoluteTimeGetCurrent()
                    do {
                        let resp = try await self!.fetch(url: url, range: range)
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                        return Outcome(url: url, elapsedMs: elapsed, result: .success(resp.data))
                    } catch {
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                        return Outcome(url: url, elapsedMs: elapsed, result: .failure(error))
                    }
                }
            }
            var attempts: [String] = []
            var errors: [Error] = []
            while let outcome = try await group.next() {
                switch outcome.result {
                case .success(let data):
                    attempts.append("\(outcome.url.host ?? "?") \(outcome.elapsedMs)ms ok")
                    group.cancelAll()
                    let raceMs = Int((CFAbsoluteTimeGetCurrent() - raceStart) * 1000)
                    return ProbeRaceOutcome(winnerURL: outcome.url,
                                            winnerElapsedMs: outcome.elapsedMs,
                                            raceMs: raceMs,
                                            data: data,
                                            attempts: attempts)
                case .failure(let err):
                    let detail = Self.debugSummary(of: err)
                    attempts.append("\(outcome.url.host ?? "?") \(outcome.elapsedMs)ms \(detail)")
                    errors.append(err)
                }
            }
            throw errors.last ?? ProxyLoaderError.allCandidatesFailed
        }
    }

    private func parseContentRangeTotal(_ value: String?) -> Int64? {
        // Content-Range: bytes 0-1023/1048576
        guard let value, let slashIdx = value.firstIndex(of: "/") else { return nil }
        let totalSlice = value[value.index(after: slashIdx)...]
        if totalSlice == "*" { return nil }
        return Int64(totalSlice)
    }

    static func debugSummary(of error: Error) -> String {
        if let proxy = error as? ProxyLoaderError, let s = proxy.errorDescription {
            return s
        }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
    }
}

struct ProbeRaceOutcome {
    let winnerURL: URL
    let winnerElapsedMs: Int
    let raceMs: Int
    let data: Data
    let attempts: [String]
}

enum ProxyLoaderError: Error, LocalizedError {
    case unexpectedResponse
    case httpStatus(Int, host: String)
    case allCandidatesFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "上游返回了非 HTTP 响应"
        case .httpStatus(let code, let host):
            return "上游返回 HTTP \(code) (\(host))"
        case .allCandidatesFailed:
            return "所有候选 CDN 均失败"
        }
    }
}
