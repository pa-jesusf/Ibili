import Foundation

/// Link resolution and the introduction share full details, scoped to credentials.
/// Explicit refresh always bypasses this short-lived cache.
@MainActor
final class VideoDetailRepository {
    static let shared = VideoDetailRepository()
    private struct Cached { let value: VideoViewDTO; let date: Date }
    private struct Flight { let id: UUID; let sequence: UInt64; let task: Task<VideoViewDTO, Error> }
    private var nextSequence: UInt64 = 0
    private var committedSequence: [Int64: UInt64] = [:]
    private var cached: [Cached] = []
    private var flights: [String: Flight] = [:]
    private var session: UUID?
    private let generation: () -> UUID
    private let load: (Int64, String) async throws -> VideoViewDTO

    init(generation: @escaping () -> UUID = { CoreClient.shared.sessionGeneration },
         load: @escaping (Int64, String) async throws -> VideoViewDTO = { aid, bvid in
             try await CoreClient.shared.perform { try $0.videoViewFull(aid: aid, bvid: bvid) }
         }) {
        self.generation = generation
        self.load = load
    }

    func detail(aid: Int64, bvid: String, force: Bool = false) async throws -> VideoViewDTO {
        try Task.checkCancellation()
        guard aid > 0 || !bvid.isEmpty else {
            throw CoreError(category: "invalid_argument", message: "缺少视频标识", code: nil)
        }
        let current = generation()
        if session != current { session = current; cached.removeAll(); flights.removeAll(); committedSequence.removeAll() }
        defer {
            // Keep ordering evidence while any older alias may still complete.
            if flights.isEmpty {
                let retained = Set(cached.map { $0.value.aid })
                committedSequence = committedSequence.filter { retained.contains($0.key) }
            }
        }
        cached.removeAll { Date().timeIntervalSince($0.date) >= 30 }
        let matches: (Cached) -> Bool = { entry in
            (aid <= 0 || aid == entry.value.aid) && (bvid.isEmpty || bvid == entry.value.bvid)
        }
        if force { cached.removeAll(where: matches) }
        else if let entry = cached.first(where: matches) { return entry.value }
        let key = bvid.isEmpty ? "av:\(aid)" : "bv:\(bvid)"
        let flight: Flight
        if !force, let running = flights[key] { flight = running }
        else {
            nextSequence &+= 1
            flight = Flight(id: UUID(), sequence: nextSequence, task: Task { [load] in try await load(aid, bvid) })
            flights[key] = flight
        }
        do {
            let value = try await flight.task.value
            guard generation() == current else { throw CancellationError() }
            if flights[key]?.id == flight.id {
                flights[key] = nil
                if (committedSequence[value.aid] ?? 0) > flight.sequence {
                    throw CancellationError()
                }
                committedSequence[value.aid] = flight.sequence
                cached.removeAll { $0.value.aid == value.aid }
                cached.append(Cached(value: value, date: Date()))
                if cached.count > 12 { cached.removeFirst(cached.count - 12) }
            }
            try Task.checkCancellation()
            return value
        } catch {
            if session == current, flights[key]?.id == flight.id { flights[key] = nil }
            throw error
        }
    }
}
