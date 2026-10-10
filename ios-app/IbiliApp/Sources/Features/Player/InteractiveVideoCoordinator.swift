import Foundation
import AVFoundation
import Combine

struct InteractivePresentation: Equatable {
    enum Phase { case hidden, loading, choices, failed, ending }
    var phase: Phase = .hidden
    var title = ""
    var choices: [InteractiveChoiceDTO] = []
    var secondsRemaining: Int? = nil
    var showsHistoryControl: Bool { phase == .choices }
}

struct InteractiveHistoryEntry: Equatable, Identifiable {
    let id: UUID
    let edgeID: Int64
    let cid: Int64
    let title: String
    let startPositionMs: Int64
}

/// One story per player session. Native time boundaries, not a per-frame
/// SwiftUI subscription, determine when a decision becomes available.
@MainActor
final class InteractiveVideoCoordinator: ObservableObject {
    typealias FetchNode = (String, Int64, Int64, [Int64], Int) async throws -> InteractiveNodeDTO
    @Published private(set) var presentation = InteractivePresentation()
    @Published private(set) var history: [InteractiveHistoryEntry] = []
    private(set) var node: InteractiveNodeDTO?
    private(set) var variables: [String: Double] = [:]
    private(set) var isEnabled = false
    private(set) var isBlocking = false
    var isTransitioning: Bool { requestTask != nil || presentation.phase == .loading }
    var transition: ((Int64, Int64) async throws -> Bool)?
    var seek: ((Double) async -> Bool)?
    var gateChanged: (() -> Void)?
    var refreshInfo: (() async throws -> InteractiveVideoInfoDTO)?
    private let fetchNode: FetchNode
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var boundary: Any?
    private var durationObservation: NSKeyValueObservation?
    private var jumpObserver: NSObjectProtocol?
    private var requestTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var generation = UUID()
    private var bvid = ""
    private var graphVersion: Int64 = 0
    private var currentCID: Int64 = 0
    private var initialEdge: Int64 = 0
    private var completed = false
    private var allowed = false
    @Published private var presentationAllowed = false
    private var answered = Set<Int>()
    private var activeQuestion: Int?
    private var midChoices: [Int64] = []
    private var remaining: Double?
    private var pendingChoice: InteractiveChoiceDTO?
    private var pendingNode: InteractiveNodeDTO?
    private var retryRestarts = false
    private var rootCID: Int64 = 0
    private var graphExpired = false
    private var metadataUnavailable = false
    private var visited: [InteractiveHistoryEntry] = []
    private struct Checkpoint {
        let variables: [String: Double]
        let answered: Set<Int>
        let midChoices: [Int64]
        let positionMs: Int64
        let completed: Bool
    }
    private var checkpoints: [UUID: Checkpoint] = [:]
    private var pendingRewind: UUID?
    private var pendingOutgoingCheckpoint: Checkpoint?

    var floatingPresentationPublisher: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest($presentation.map(\.phase).removeDuplicates(), $presentationAllowed.removeDuplicates())
            .map { phase, mayPresent in mayPresent && phase != .hidden }
            .removeDuplicates().eraseToAnyPublisher()
    }

    init(fetchNode: @escaping FetchNode = { bvid, graph, edge, choices, portal in
        try await CoreClient.shared.perform {
            try $0.interactiveVideoNode(bvid: bvid, graphVersion: graph, edgeID: edge, choices: choices, portal: portal)
        }
    }) { self.fetchNode = fetchNode }

    func bind(player: AVPlayer, item: AVPlayerItem, bvid: String, cid: Int64,
              info: InteractiveVideoInfoDTO?, allowed: Bool, presentationAllowed: Bool? = nil) {
        guard let info, info.graphVersion > 0 else {
            // A quality/recovery response may omit optional player info. The
            // current graph remains authoritative for the same video/session.
            if isEnabled, self.bvid == bvid, currentCID == cid {
                attach(player: player, item: item)
                playbackStateChanged(allowed: allowed, presentationAllowed: presentationAllowed)
                return
            }
            reset(); return
        }
        if !isEnabled || self.bvid != bvid || graphVersion != info.graphVersion {
            reset()
            self.bvid = bvid; graphVersion = info.graphVersion; currentCID = cid
            rootCID = cid
            if let history = info.historyNode, history.cid == cid, history.nodeID > 0 { initialEdge = history.nodeID }
            isEnabled = true
        }
        attach(player: player, item: item)
        playbackStateChanged(allowed: allowed, presentationAllowed: presentationAllowed)
        if node == nil, requestTask == nil { loadInitialNode() }
    }

    func requireMetadata(player: AVPlayer, item: AVPlayerItem, bvid: String, cid: Int64,
                         allowed: Bool, presentationAllowed: Bool? = nil) {
        guard !isEnabled else { return }
        self.bvid = bvid; currentCID = cid; rootCID = cid
        isEnabled = true; metadataUnavailable = true
        attach(player: player, item: item)
        self.allowed = allowed
        self.presentationAllowed = presentationAllowed ?? allowed
        refreshMetadata()
    }

    private func attach(player: AVPlayer, item: AVPlayerItem) {
        guard self.player !== player || self.item !== item else { return }
        detachTimeline()
        self.player = player; self.item = item
        completed = false
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.item === item else { return }
                self.installBoundaries(); self.evaluate()
            }
        }
        jumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.item === item else { return }
                let duration = item.duration.seconds, time = self.player?.currentTime().seconds ?? 0
                self.completed = duration.isFinite && duration > 0 && time >= duration - 0.025
                if self.presentation.phase == .ending { self.setPresentation(.init(), blocking: false) }
                self.evaluate()
            }
        }
        installBoundaries()
    }

    func replaceItemBinding(player: AVPlayer, item: AVPlayerItem) {
        attach(player: player, item: item)
    }

    func reset() {
        generation = UUID()
        requestTask?.cancel(); requestTask = nil
        countdownTask?.cancel(); countdownTask = nil
        detachTimeline()
        node = nil; variables = [:]; isEnabled = false
        bvid = ""; graphVersion = 0; initialEdge = 0; currentCID = 0; rootCID = 0
        answered = []; activeQuestion = nil; midChoices = []; pendingChoice = nil; pendingNode = nil; retryRestarts = false
        remaining = nil; completed = false; graphExpired = false; metadataUnavailable = false
        visited = []; checkpoints = [:]; pendingRewind = nil; pendingOutgoingCheckpoint = nil; history = []
        presentationAllowed = false
        setPresentation(.init(), blocking: false)
    }

    private func detachTimeline() {
        if let boundary, let player { player.removeTimeObserver(boundary) }
        boundary = nil
        durationObservation = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        player = nil; item = nil
    }

    private func loadInitialNode() {
        guard isEnabled, requestTask == nil else { return }
        let token = generation, bv = bvid, graph = graphVersion, edge = initialEdge, cid = currentCID
        setPresentation(.init(phase: .loading, title: "加载剧情…"), blocking: completed)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await fetchNode(bv, graph, edge, [], 0)
                guard !Task.isCancelled, generation == token else { return }
                guard result.edgeID > 0, edge == 0 || result.edgeID == edge,
                      result.storyList.contains(where: { $0.edgeID == result.edgeID && $0.cid == cid }) else {
                    throw StoryError("当前视频片段与剧情节点不匹配")
                }
                node = result
                if let root = result.storyList.first { rootCID = root.cid }
                variables = Dictionary(result.hiddenVars.map { ($0.idV2, $0.value) }, uniquingKeysWith: { _, new in new })
                initializeHistory(result)
                requestTask = nil
                setPresentation(.init(), blocking: false)
                installBoundaries(); evaluate()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                requestTask = nil; fail(error)
            }
        }
    }

    private func installBoundaries() {
        if let boundary, let player { player.removeTimeObserver(boundary) }
        boundary = nil
        guard let node, let player, let item, player.currentItem === item else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let times = node.edges.questions.flatMap { q -> [NSValue] in
            let start = q.triggerSeconds(videoDuration: duration)
            var values = [max(0.001, start)]
            if q.type == 4, q.duration > 0 { values.append(start + Double(q.duration) / 1000) }
            return values.filter { $0 < duration }.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 1000)) }
        }
        guard !times.isEmpty else { return }
        boundary = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self, weak item] in
            Task { @MainActor in
                guard let self, let item, self.item === item else { return }
                self.evaluate()
            }
        }
    }

    func playbackStateChanged(allowed: Bool, presentationAllowed: Bool? = nil) {
        self.allowed = allowed
        self.presentationAllowed = presentationAllowed ?? allowed
        if !allowed { countdownTask?.cancel(); countdownTask = nil }
        else { evaluate(); startCountdownIfNeeded() }
    }

    /// Consumes the end event even while the node request is still loading.
    /// Ordinary next-part/loop preferences never choose a story branch.
    func handleCompletion() -> Bool {
        guard isEnabled else { return false }
        completed = true
        setBlocking(true)
        evaluate()
        return true
    }

    private func evaluate() {
        guard isEnabled, requestTask == nil, presentation.phase != .failed, presentation.phase != .loading,
              let node, let player, let item, player.currentItem === item else { return }
        let duration = item.duration.seconds, time = player.currentTime().seconds
        guard duration.isFinite, duration > 0, time.isFinite else { return }
        if let activeQuestion {
            let q = node.edges.questions[activeQuestion]
            if !completed, time + 0.05 < q.triggerSeconds(videoDuration: duration) {
                self.activeQuestion = nil; remaining = nil
                countdownTask?.cancel(); countdownTask = nil
                setPresentation(.init(), blocking: false)
            } else {
                if allowed, presentation.phase == .choices, remaining == nil,
                   q.type == 0 || presentation.choices.isEmpty {
                    do {
                        if let choice = try q.choices.first(where: {
                            guard $0.isDefault == 1 else { return false }
                            return try conditionMatches($0)
                        }) { choose(choice) }
                    } catch { fail(error) }
                }
                return
            }
        }
        if node.isLeaf == 1, completed {
            setPresentation(.init(phase: .ending, title: "剧情结束"), blocking: true); return
        }
        for (index, q) in node.edges.questions.enumerated() where !answered.contains(index) {
            if !completed, time + 0.025 < q.triggerSeconds(videoDuration: duration) { continue }
            do {
                guard [0, 1, 2, 4].contains(q.type) else { throw StoryError("此视频使用暂不支持的特殊互动形式") }
                let eligible = try q.choices.filter {
                    try conditionMatches($0)
                }
                guard !eligible.isEmpty else { throw StoryError("当前剧情没有可用选项") }
                activeQuestion = index
                let visible = q.type == 0 ? [] : eligible.filter { $0.isHidden != 1 }
                if q.duration > 0, !(q.type == 4 && q.pauseVideo == 1) {
                    let end = q.type == 4 ? q.triggerSeconds(videoDuration: duration) + Double(q.duration) / 1000 : duration
                    remaining = max(0, min(Double(q.duration) / 1000, end - time))
                } else { remaining = nil }
                setPresentation(.init(phase: .choices, title: q.title.isEmpty ? "选择接下来的剧情" : q.title,
                                      choices: visible, secondsRemaining: remaining.map { Int(ceil($0)) }),
                                blocking: completed || q.type == 4 && q.pauseVideo == 1)
                if remaining == nil, q.type == 0 || visible.isEmpty {
                    guard let choice = eligible.first(where: { $0.isDefault == 1 }) else { throw StoryError("剧情缺少默认分支") }
                    choose(choice)
                } else { startCountdownIfNeeded() }
            } catch { fail(error) }
            return
        }
        if completed { fail(StoryError("当前剧情没有结束标记或后续分支")) }
    }

    func choose(_ choice: InteractiveChoiceDTO) {
        guard allowed, requestTask == nil, let player, let item, player.currentItem === item,
              let node, let index = activeQuestion,
              let actual = node.edges.questions[index].choices.first(where: { $0 == choice }) else { return }
        let q = node.edges.questions[index]
        let token = generation, bv = bvid, graph = graphVersion, choiceIDs = midChoices
        let cachedNode = pendingChoice == actual ? pendingNode : nil
        let outgoingCheckpoint = pendingChoice == actual ? pendingOutgoingCheckpoint ?? checkpoint() : checkpoint()
        do {
            guard try conditionMatches(actual) else { return }
            let candidateVariables = try InteractiveExpression.applying(actual.nativeAction, to: variables)
            if q.type != 4, (actual.cid <= 0 || actual.id <= 0) { throw StoryError("剧情分支缺少可播放的片段") }
            countdownTask?.cancel(); countdownTask = nil
            pendingChoice = actual
            pendingOutgoingCheckpoint = outgoingCheckpoint
            pendingRewind = nil
            pendingNode = cachedNode
            retryRestarts = false
            setPresentation(.init(phase: .loading, title: q.type == 4 ? "继续剧情…" : "加载下一段…"), blocking: true)
            requestTask = Task { [weak self] in
                guard let self else { return }
                do {
                    if q.type == 4 {
                        if !actual.platformAction.isEmpty {
                            let parts = actual.platformAction.split(separator: " ")
                            guard parts.count == 2, parts[0] == "SEEK", let seconds = Double(parts[1]),
                                  seconds.isFinite, seconds >= 0, let seek, await seek(seconds) else {
                                throw StoryError("无法执行此剧情的进度跳转")
                            }
                        }
                        guard generation == token, !Task.isCancelled else { return }
                        variables = candidateVariables; midChoices.append(actual.id); answered.insert(index)
                        activeQuestion = nil; pendingChoice = nil; pendingOutgoingCheckpoint = nil; remaining = nil; requestTask = nil
                        setPresentation(.init(), blocking: false); evaluate()
                    } else {
                        let next: InteractiveNodeDTO
                        if let cachedNode { next = cachedNode }
                        else { next = try await fetchNode(bv, graph, actual.id, choiceIDs, 0) }
                        guard generation == token, !Task.isCancelled else { return }
                        guard next.edgeID == actual.id, let transition else { throw StoryError("剧情节点不匹配") }
                        pendingNode = next
                        guard try await transition(actual.cid, 0) else { throw CancellationError() }
                        guard generation == token, !Task.isCancelled else { return }
                        // The server applies `choices` for signed-in accounts.
                        // Local ordinary variables retain the chosen actions;
                        // new/random variables use the current node's response.
                        var nextVariables = candidateVariables
                        for v in next.hiddenVars where v.type == 2 || nextVariables[v.idV2] == nil { nextVariables[v.idV2] = v.value }
                        self.node = next; variables = nextVariables; currentCID = actual.cid
                        if let previous = visited.last { checkpoints[previous.id] = outgoingCheckpoint }
                        answered = []; midChoices = []; activeQuestion = nil; pendingChoice = nil; pendingNode = nil; pendingOutgoingCheckpoint = nil
                        remaining = nil; completed = false; requestTask = nil
                        appendHistory(next, cid: actual.cid)
                        setPresentation(.init(), blocking: false)
                        installBoundaries(); evaluate()
                    }
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    requestTask = nil; fail(error)
                }
            }
        } catch { fail(error) }
    }

    private func startCountdownIfNeeded() {
        guard allowed, presentation.phase == .choices, remaining != nil, countdownTask == nil else { return }
        countdownTask = Task { [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, allowed, presentation.phase == .choices, remaining != nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                updateCountdown(elapsed: now - previous)
                previous = now
                if remaining == nil || presentation.phase != .choices { return }
            }
        }
    }

    func updateCountdown(elapsed: TimeInterval) {
        guard allowed, presentation.phase == .choices, let left = remaining else { return }
        // Stop countdown when the viewer pauses or the app is covered.
        if player?.rate ?? 0 > 0 || completed { remaining = max(0, left - max(0, elapsed)) }
        let seconds = Int(ceil(remaining ?? 0))
        if presentation.secondsRemaining != seconds { presentation.secondsRemaining = seconds }
        guard seconds <= 0, let index = activeQuestion, let node else { return }
        countdownTask?.cancel(); countdownTask = nil
        do {
            let choice = try node.edges.questions[index].choices.first {
                guard $0.isDefault == 1 else { return false }
                return try conditionMatches($0)
            }
            guard let choice else { throw StoryError("剧情缺少可用的默认分支") }
            choose(choice)
        } catch { fail(error) }
    }

    func retry() {
        guard allowed, requestTask == nil else { return }
        if graphExpired { restart(); return }
        if metadataUnavailable { refreshMetadata(); return }
        if retryRestarts { restart(); return }
        if let pendingRewind { rewind(to: pendingRewind); return }
        if let pendingChoice { choose(pendingChoice) }
        else if node == nil { loadInitialNode() }
        else { setPresentation(.init(), blocking: false); activeQuestion = nil; evaluate() }
    }

    func restart() {
        if metadataUnavailable { refreshMetadata(); return }
        guard allowed, requestTask == nil, rootCID > 0, let transition else { return }
        let token = generation, bv = bvid, graph = graphVersion
        retryRestarts = true
        pendingRewind = nil
        pendingChoice = nil; pendingNode = nil; pendingOutgoingCheckpoint = nil
        setPresentation(.init(phase: .loading, title: "重新开始剧情…"), blocking: true)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await refreshInfo?()
                guard generation == token, !Task.isCancelled else { return }
                let activeGraph = refreshed?.graphVersion ?? graph
                let root = try await fetchNode(bv, activeGraph, 0, [], 1)
                guard generation == token, !Task.isCancelled,
                      let story = root.storyList.first(where: { $0.edgeID == root.edgeID }), story.cid > 0 else { throw StoryError("起始剧情不匹配") }
                let cid = story.cid
                guard try await transition(cid, 0) else { throw CancellationError() }
                guard generation == token, !Task.isCancelled else { return }
                node = root; currentCID = cid; rootCID = cid; initialEdge = root.edgeID
                graphVersion = activeGraph; graphExpired = false
                variables = Dictionary(root.hiddenVars.map { ($0.idV2, $0.value) }, uniquingKeysWith: { _, new in new })
                answered = []; midChoices = []; activeQuestion = nil; pendingChoice = nil; pendingNode = nil; retryRestarts = false
                remaining = nil; completed = false; requestTask = nil
                visited = []; checkpoints = [:]
                appendHistory(root, cid: cid)
                setPresentation(.init(), blocking: false); installBoundaries(); evaluate()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                requestTask = nil; fail(error)
            }
        }
    }

    /// Only visited nodes are accepted. Portal 1 restores the server's story
    /// checkpoint; local snapshots preserve anonymous and in-video decisions.
    func rewind(to id: UUID) {
        guard allowed, !isTransitioning, node?.noBacktracking == 0,
              let index = visited.firstIndex(where: { $0.id == id }), let transition else { return }
        let target = visited[index], saved = checkpoints[id]
        let token = generation, bv = bvid, graph = graphVersion
        let cached = pendingRewind == id ? pendingNode : nil
        pendingChoice = nil; pendingOutgoingCheckpoint = nil; pendingRewind = id; retryRestarts = false
        pendingNode = cached
        countdownTask?.cancel(); countdownTask = nil
        setPresentation(.init(phase: .loading, title: "回溯剧情…"), blocking: true)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let restored: InteractiveNodeDTO
                if let cached { restored = cached }
                else { restored = try await fetchNode(bv, graph, target.edgeID, [], 1) }
                guard generation == token, !Task.isCancelled else { return }
                guard restored.edgeID == target.edgeID else { throw StoryError("回溯剧情节点不匹配") }
                pendingNode = restored
                guard try await transition(target.cid, saved?.positionMs ?? target.startPositionMs) else { throw CancellationError() }
                guard generation == token, !Task.isCancelled else { return }
                node = restored; currentCID = target.cid
                variables = saved?.variables ?? Dictionary(restored.hiddenVars.map { ($0.idV2, $0.value) }, uniquingKeysWith: { _, new in new })
                for v in restored.hiddenVars where variables[v.idV2] == nil { variables[v.idV2] = v.value }
                answered = saved?.answered ?? []; midChoices = saved?.midChoices ?? []
                activeQuestion = nil; remaining = nil; completed = saved?.completed ?? false
                visited = Array(visited.prefix(index + 1))
                let retained = Set(visited.map(\.id)); checkpoints = checkpoints.filter { retained.contains($0.key) }
                pendingRewind = nil; pendingNode = nil; requestTask = nil
                publishHistory()
                setPresentation(.init(), blocking: completed)
                installBoundaries(); evaluate()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                requestTask = nil; fail(error)
            }
        }
    }

    private func checkpoint() -> Checkpoint {
        var seconds = player?.currentTime().seconds ?? 0
        var ended = completed
        if let node, let activeQuestion, let item {
            let q = node.edges.questions[activeQuestion]
            if q.type != 4, q.duration > 0, item.duration.seconds.isFinite {
                // A timed choice must reopen its decision window, otherwise a
                // rewind from the end immediately takes the same default again.
                seconds = q.triggerSeconds(videoDuration: item.duration.seconds)
                ended = false
            }
        }
        let ms = seconds.isFinite && seconds >= 0 && seconds < Double(Int64.max) / 1000 ? Int64(seconds * 1000) : 0
        return Checkpoint(variables: variables, answered: answered, midChoices: midChoices,
                          positionMs: ms, completed: ended)
    }

    private func initializeHistory(_ result: InteractiveNodeDTO) {
        visited = []; checkpoints = [:]
        if let currentIndex = result.storyList.lastIndex(where: { $0.edgeID == result.edgeID && $0.cid == currentCID }) {
            visited = result.storyList.prefix(currentIndex + 1).filter { $0.edgeID > 0 && $0.cid > 0 }.suffix(256).map {
                .init(id: UUID(), edgeID: $0.edgeID, cid: $0.cid, title: $0.title, startPositionMs: max(0, $0.startPos))
            }
        }
        if visited.isEmpty { appendHistory(result, cid: currentCID) }
        else {
            if let current = visited.last {
                checkpoints[current.id] = .init(variables: variables, answered: [], midChoices: [], positionMs: 0, completed: false)
            }
            publishHistory()
        }
    }

    private func appendHistory(_ result: InteractiveNodeDTO, cid: Int64) {
        let entry = InteractiveHistoryEntry(id: UUID(), edgeID: result.edgeID, cid: cid,
                                            title: result.title.isEmpty ? "剧情 \(visited.count + 1)" : result.title,
                                            startPositionMs: 0)
        visited.append(entry)
        checkpoints[entry.id] = .init(variables: variables, answered: [], midChoices: [], positionMs: 0, completed: false)
        // Stories may contain loops. Keep a bounded recent path, not a graph
        // cache that grows forever while the player session remains alive.
        if visited.count > 256 {
            for removed in visited.prefix(visited.count - 256) { checkpoints[removed.id] = nil }
            visited.removeFirst(visited.count - 256)
        }
        publishHistory()
    }

    private func publishHistory() {
        let visible = node?.noBacktracking == 0 ? visited : []
        if history != visible { history = visible }
    }

    private func fail(_ error: Error) {
        countdownTask?.cancel(); countdownTask = nil
        graphExpired = (error as? CoreError)?.code == 99003
        let message = graphExpired ? "剧情图已更新，请重新开始" : error.localizedDescription
        setPresentation(.init(phase: .failed, title: message), blocking: true)
        AppLog.warning("player", "互动剧情加载失败", metadata: ["bvid": bvid, "graphVersion": String(graphVersion), "error": error.localizedDescription])
    }
    private func conditionMatches(_ choice: InteractiveChoiceDTO) throws -> Bool {
        if choice.condition.isEmpty { return true }
        return try InteractiveExpression.evaluate(choice.condition, variables: variables) != 0
    }

    private func refreshMetadata() {
        guard requestTask == nil, let refreshInfo, let player, let item = player.currentItem else { return }
        attach(player: player, item: item)
        let token = generation, bv = bvid, cid = currentCID
        setPresentation(.init(phase: .loading, title: "加载剧情…"), blocking: true)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await refreshInfo()
                guard generation == token, !Task.isCancelled else { return }
                guard self.player === player, self.item === item, player.currentItem === item else {
                    requestTask = nil
                    fail(StoryError("播放片段已变化，请重试剧情加载"))
                    return
                }
                let wasCompleted = completed
                requestTask = nil; isEnabled = false
                bind(player: player, item: item, bvid: bv, cid: cid, info: info,
                     allowed: allowed, presentationAllowed: presentationAllowed)
                if wasCompleted { _ = handleCompletion() }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                requestTask = nil; fail(error)
            }
        }
    }
    private func setPresentation(_ value: InteractivePresentation, blocking: Bool) {
        if presentation != value { presentation = value }
        setBlocking(blocking)
    }
    private func setBlocking(_ value: Bool) {
        guard isBlocking != value else { return }
        isBlocking = value; gateChanged?()
    }
    struct StoryError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
