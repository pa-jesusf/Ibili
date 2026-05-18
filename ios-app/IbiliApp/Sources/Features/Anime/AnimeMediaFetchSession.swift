import Foundation

@MainActor
final class AnimeMediaFetchSession {
    let snapshots: AsyncStream<AnimeMediaSessionSnapshotDTO>

    private let route: DeepLinkRouter.AnimePlayerRoute
    private let sources: [AnimeSourceDTO]
    private let subjectNames: [String]
    private let sourceJSONByID: [String: String]
    private var continuation: AsyncStream<AnimeMediaSessionSnapshotDTO>.Continuation?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var reportsBySourceID: [String: AnimeMediaSourceReportDTO] = [:]
    private var candidatesByID: [String: AnimeMediaCandidateDTO] = [:]
    private var temporarilyEnabled = Set<String>()
    private var isStarted = false
    private let initialConcurrentSourceLimit = 12

    init(
        route: DeepLinkRouter.AnimePlayerRoute,
        sources: [AnimeSourceDTO],
        sourceJSONByID: [String: String]
    ) {
        self.route = route
        self.sources = sources
        self.subjectNames = [route.subject.nameCn, route.subject.name] + route.subject.aliases
        self.sourceJSONByID = sourceJSONByID
        var captured: AsyncStream<AnimeMediaSessionSnapshotDTO>.Continuation?
        self.snapshots = AsyncStream { continuation in
            captured = continuation
        }
        self.continuation = captured
        self.reportsBySourceID = Dictionary(uniqueKeysWithValues: sources.map { source in
            (source.id, Self.pendingReport(for: source))
        })
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        emitSnapshot()
        AppLog.info("anime", "追番检索 session 启动", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "sources": String(sources.count),
        ])
        for (index, source) in orderedSources().enumerated() {
            startSource(source, delayMs: initialDelayMs(for: source, index: index))
        }
    }

    func restartAll() {
        candidatesByID.removeAll()
        reportsBySourceID = Dictionary(uniqueKeysWithValues: sources.map { source in
            (source.id, Self.pendingReport(for: source))
        })
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        emitSnapshot()
        for (index, source) in orderedSources().enumerated() {
            startSource(source, delayMs: initialDelayMs(for: source, index: index))
        }
    }

    func restartSource(_ sourceID: String, captchaSession: AnimeCaptchaSessionDTO? = nil) async {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        tasks[sourceID]?.cancel()
        tasks[sourceID] = nil
        candidatesByID = candidatesByID.filter { $0.value.sourceID != sourceID }
        reportsBySourceID[sourceID] = Self.pendingReport(for: source, temporarilyEnabled: temporarilyEnabled.contains(sourceID))
        emitSnapshot()
        startSource(source, captchaSession: captchaSession)
    }

    func enableTemporarily(_ sourceID: String) {
        temporarilyEnabled.insert(sourceID)
        if let report = reportsBySourceID[sourceID] {
            reportsBySourceID[sourceID] = report.withTemporaryEnabled(true)
        }
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        if tasks[sourceID] == nil {
            startSource(source)
        }
        emitSnapshot()
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        continuation?.finish()
    }

    private func orderedSources() -> [AnimeSourceDTO] {
        let preferred = UserDefaults.standard.string(forKey: preferredSourceKey)
        return sources.sorted { left, right in
            if left.id == preferred { return true }
            if right.id == preferred { return false }
            let leftTier = Self.tierPriority(left.tier)
            let rightTier = Self.tierPriority(right.tier)
            if leftTier != rightTier { return leftTier < rightTier }
            return left.name < right.name
        }
    }

    private var preferredSourceKey: String {
        "ibili.anime.preferredSource.\(route.subject.id)"
    }

    private func startSource(
        _ source: AnimeSourceDTO,
        captchaSession: AnimeCaptchaSessionDTO? = nil,
        delayMs: Int = 0
    ) {
        guard source.enabled || temporarilyEnabled.contains(source.id) else {
            reportsBySourceID[source.id] = Self.disabledReport(for: source)
            emitSnapshot()
            return
        }
        tasks[source.id]?.cancel()
        reportsBySourceID[source.id] = Self.workingReport(
            from: reportsBySourceID[source.id] ?? Self.pendingReport(for: source),
            temporarilyEnabled: temporarilyEnabled.contains(source.id)
        )
        emitSnapshot()
        tasks[source.id] = Task { [weak self] in
            guard let self else { return }
            do {
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                }
                guard let sourceJSON = self.sourceJSONByID[source.id] else {
                    throw CoreError(category: "anime_source", message: "数据源配置缺失", code: nil)
                }
                let result = try await self.fetch(source: source, sourceJSON: sourceJSON, captchaSession: captchaSession)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.apply(result: result, for: source)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.apply(error: error, for: source, captchaSession: captchaSession)
                }
            }
        }
    }

    private func initialDelayMs(for source: AnimeSourceDTO, index: Int) -> Int {
        guard index >= initialConcurrentSourceLimit else { return 0 }
        let interval = max(0, source.requestIntervalMs)
        return min(2_000, interval) * ((index - initialConcurrentSourceLimit) / initialConcurrentSourceLimit + 1)
    }

    private func fetch(
        source: AnimeSourceDTO,
        sourceJSON: String,
        captchaSession: AnimeCaptchaSessionDTO?
    ) async throws -> AnimeMediaFetchResultDTO {
        let names = Array(subjectNames.prefix(source.searchUseSubjectNamesCount))
        let route = route
        return try await Task.detached(priority: .userInitiated) {
            if let captchaSession, !captchaSession.html.isEmpty {
                return try CoreClient.shared.animeMediaSourceParsePage(
                    sourceJSON: sourceJSON,
                    pageURL: captchaSession.finalURL.isEmpty ? captchaSession.pageURL : captchaSession.finalURL,
                    html: captchaSession.html,
                    subjectNames: names,
                    episodeSort: route.episode.sort,
                    episodeName: route.episode.displayTitle
                )
            }
            return try CoreClient.shared.animeMediaSourceFetch(
                sourceJSON: sourceJSON,
                subjectNames: names,
                episodeSort: route.episode.sort,
                episodeName: route.episode.displayTitle
            )
        }.value
    }

    private func apply(result: AnimeMediaFetchResultDTO, for source: AnimeSourceDTO) {
        tasks[source.id] = nil
        for candidate in result.candidates {
            candidatesByID[candidate.id] = candidate
        }
        if let report = result.diagnostics.sourceReports.first {
            reportsBySourceID[source.id] = report.withTemporaryEnabled(temporarilyEnabled.contains(source.id))
        } else {
            reportsBySourceID[source.id] = Self.emptyReport(for: source)
        }
        if result.candidates.contains(where: \.isPlayableOrSniffable) {
            UserDefaults.standard.set(source.id, forKey: preferredSourceKey)
        }
        AppLog.info("anime", "追番单源检索完成", metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "sourceID": source.id,
            "source": source.name,
            "candidateCount": String(result.candidates.count),
            "supportedCandidates": String(result.diagnostics.supportedCandidates),
            "status": reportsBySourceID[source.id]?.status ?? "",
        ])
        emitSnapshot()
    }

    private func apply(error: Error, for source: AnimeSourceDTO, captchaSession: AnimeCaptchaSessionDTO?) {
        tasks[source.id] = nil
        var report = reportsBySourceID[source.id] ?? Self.pendingReport(for: source)
        report = report.finishedFailure(message: error.localizedDescription)
        reportsBySourceID[source.id] = report
        AppLog.error("anime", "追番单源检索失败", error: error, metadata: [
            "subjectID": String(route.subject.id),
            "episodeID": String(route.episode.id),
            "sourceID": source.id,
            "source": source.name,
            "fromCaptchaSession": captchaSession == nil ? "false" : "true",
        ])
        emitSnapshot()
    }

    private func emitSnapshot() {
        let candidates = Self.sortedCandidates(Array(candidatesByID.values))
        let reports = Self.sortedReports(Array(reportsBySourceID.values), sourceOrder: orderedSources().map(\.id))
        let diagnostics = AnimeMediaFetchDiagnosticsDTO(
            enabledSources: Int64(sources.filter { $0.enabled || temporarilyEnabled.contains($0.id) }.count),
            attemptedQueries: reports.reduce(Int64(0)) { $0 + $1.attemptedQueries },
            succeededQueries: reports.reduce(Int64(0)) { $0 + $1.succeededQueries },
            failedQueries: reports.reduce(Int64(0)) { $0 + $1.failedQueries },
            unsupportedCandidates: Int64(candidates.filter { !$0.isPlayableOrSniffable }.count),
            supportedCandidates: Int64(candidates.filter(\.isPlayableOrSniffable).count),
            messages: Array(reports.compactMap { report in
                report.message.isEmpty ? nil : "\(report.sourceName)：\(report.message)"
            }.prefix(8)),
            sourceReports: reports
        )
        continuation?.yield(AnimeMediaSessionSnapshotDTO(
            diagnostics: diagnostics,
            candidates: candidates,
            currentCandidateID: nil,
            isComplete: !reports.contains(where: { $0.status == "pending" || $0.status == "searching" })
        ))
    }

    private static func pendingReport(for source: AnimeSourceDTO, temporarilyEnabled: Bool = false) -> AnimeMediaSourceReportDTO {
        AnimeMediaSourceReportDTO(
            sourceID: source.id,
            sourceName: source.name,
            factoryID: source.factoryID,
            stateID: "pending",
            isWorking: false,
            isTemporarilyEnabled: temporarilyEnabled,
            attemptedQueries: 0,
            succeededQueries: 0,
            failedQueries: 0,
            candidateCount: 0,
            supportedCount: 0,
            status: "pending",
            message: "等待检索",
            captchaURL: "",
            captchaKind: ""
        )
    }

    private static func workingReport(from report: AnimeMediaSourceReportDTO, temporarilyEnabled: Bool) -> AnimeMediaSourceReportDTO {
        report.replacing(status: "searching", stateID: "working", isWorking: true, isTemporarilyEnabled: temporarilyEnabled, message: "正在检索")
    }

    private static func disabledReport(for source: AnimeSourceDTO) -> AnimeMediaSourceReportDTO {
        pendingReport(for: source).replacing(status: "disabled", stateID: "disabled", isWorking: false, message: "数据源已停用")
    }

    private static func emptyReport(for source: AnimeSourceDTO) -> AnimeMediaSourceReportDTO {
        pendingReport(for: source).replacing(status: "empty", stateID: "empty", isWorking: false, message: "没有匹配结果")
    }

    private static func sortedReports(_ reports: [AnimeMediaSourceReportDTO], sourceOrder: [String]) -> [AnimeMediaSourceReportDTO] {
        let order = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
        return reports.sorted {
            let leftRank = statusRank($0.status)
            let rightRank = statusRank($1.status)
            if leftRank != rightRank { return leftRank < rightRank }
            if $0.supportedCount != $1.supportedCount { return $0.supportedCount > $1.supportedCount }
            return (order[$0.sourceID] ?? Int.max) < (order[$1.sourceID] ?? Int.max)
        }
    }

    private static func sortedCandidates(_ candidates: [AnimeMediaCandidateDTO]) -> [AnimeMediaCandidateDTO] {
        candidates.sorted {
            if $0.isPlayableOrSniffable != $1.isPlayableOrSniffable { return $0.isPlayableOrSniffable && !$1.isPlayableOrSniffable }
            let leftKind = kindPriority($0.kind)
            let rightKind = kindPriority($1.kind)
            if leftKind != rightKind { return leftKind < rightKind }
            let left = qualityScore($0.qualityLabel)
            let right = qualityScore($1.qualityLabel)
            if left != right { return left > right }
            return $0.sourceName < $1.sourceName
        }
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case "found": return 0
        case "searching": return 1
        case "captcha": return 2
        case "empty": return 3
        case "unsupported": return 4
        case "disabled": return 5
        case "failed": return 6
        default: return 7
        }
    }

    private static func tierPriority(_ tier: String) -> Int {
        switch tier.lowercased() {
        case "fast", "快速": return 0
        case "normal", "medium", "default", "普通": return 1
        case "slow", "fallback", "兜底": return 2
        default: return 1
        }
    }

    private static func kindPriority(_ kind: String) -> Int {
        switch kind {
        case "hls": return 0
        case "mp4", "m4v": return 1
        case "web": return 2
        default: return 3
        }
    }

    private static func qualityScore(_ value: String) -> Int {
        let upper = value.uppercased()
        if upper.contains("4K") || upper.contains("2160") { return 2160 }
        if upper.contains("1080") { return 1080 }
        if upper.contains("720") { return 720 }
        if upper.contains("480") { return 480 }
        if upper.contains("360") { return 360 }
        return 0
    }
}
