import AVFoundation
import Combine
import Foundation

enum SponsorSyncState: Equatable {
    case disabled, unavailable, loading, ready, empty, cachedFailure, failed, offline, offlineEmpty
    var label: String {
        switch self {
        case .disabled: return "空降助手已关闭"
        case .unavailable: return "当前视频尚未就绪或不支持社区标记"
        case .loading: return "正在同步社区标记"
        case .ready: return "社区标记已同步"
        case .empty: return "暂无社区标记"
        case .cachedFailure: return "同步暂不可用，正在使用已保存的标记"
        case .failed: return "暂时无法同步社区标记"
        case .offline: return "正在使用离线标记"
        case .offlineEmpty: return "此视频尚未保存离线标记"
        }
    }
}

enum SponsorNotice: Equatable {
    case manual(SponsorInterval)
    case skipped(label: String, from: Double, interval: SponsorInterval)
    var label: String {
        switch self {
        case .manual(let interval): return "跳过\(interval.label)"
        case .skipped(let label, _, _): return "已跳过\(label)"
        }
    }
}

/// One owner per PlayerSessionID. UI is published only on annotation/notice
/// changes; playback uses AVPlayer boundary events, never a per-frame timer.
@MainActor
final class SponsorBlockPlaybackCoordinator: ObservableObject {
    @Published private(set) var syncState: SponsorSyncState = .disabled
    @Published private(set) var segments: [SponsorSegment] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var notice: SponsorNotice?
    @Published private(set) var noticeSecondsRemaining = 0
    @Published private(set) var key: SponsorVideoKey?
    private let sessionID: PlayerSessionID
    private let repository: SponsorBlockRepository
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var boundaryToken: Any?
    private var jumpToken: NSObjectProtocol?
    private var syncTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var generation = UUID()
    private var syncGeneration = UUID()
    private var seekGeneration = UUID()
    private var boundaryGeneration = UUID()
    private var ownSeekTarget: Double?
    private var submittedSeekID: UUID?
    private var completedSeek: (target: Double, expiresAt: TimeInterval)?
    private var seekEventWatermark: UInt64 = 0
    private var lastUserSeekPosition: Double?
    private var initialPosition: Double?
    private var initialPositionRecordedAt: TimeInterval = 0
    private var timeline = SponsorTimeline()
    private var configuration = SponsorConfiguration()
    private var playbackAllowed = false
    private var offlineOnly = false
    private var offlineDirectories: [URL] = []
    private var hasSnapshot = false
    private let now: () -> TimeInterval
    private var noticeDeadline: TimeInterval?
    private var noticeGeneration = UUID()
    private var dismissedManualIDs: Set<String> = []
    static let noticeDuration: TimeInterval = 6

    init(sessionID: PlayerSessionID, repository: SponsorBlockRepository = .shared,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sessionID = sessionID
        self.repository = repository
        self.now = now
    }

    func bind(player: AVPlayer, item: AVPlayerItem, key: SponsorVideoKey,
              offlineOnly: Bool, offlineDirectories: [URL], configuration: SponsorConfiguration,
              playbackAllowed: Bool) {
        if self.player === player, self.item === item, self.key == key {
            configure(configuration)
            playbackStateChanged(allowed: playbackAllowed)
            return
        }
        detach()
        self.player = player
        self.item = item
        self.key = key
        self.offlineOnly = offlineOnly
        self.offlineDirectories = offlineDirectories
        self.playbackAllowed = playbackAllowed
        self.configuration = configuration
        // The initial history/local-resume seek can post its notification
        // after binding. It is the starting position, not a new user gesture.
        initialPosition = player.currentTime().seconds
        initialPositionRecordedAt = now()
        guard key.isValid else { syncState = .unavailable; return }
        if configuration.enabled { startSync(force: false) }
    }

    func detach() {
        generation = UUID()
        syncGeneration = UUID()
        seekGeneration = UUID()
        syncTask?.cancel(); syncTask = nil
        noticeTask?.cancel(); noticeTask = nil
        seekTask?.cancel(); seekTask = nil
        removeObservers()
        ownSeekTarget = nil
        submittedSeekID = nil
        completedSeek = nil
        lastUserSeekPosition = nil
        initialPosition = nil
        player = nil; item = nil; key = nil
        segments = []; fetchedAt = nil
        setNotice(nil)
        dismissedManualIDs = []
        timeline = SponsorTimeline()
        hasSnapshot = false
        syncState = .disabled
    }

    func configure(_ value: SponsorConfiguration) {
        let wasEnabled = key.map { configuration.isEnabled(for: $0.bvid) } ?? false
        configuration = value
        guard let key, key.isValid else { return }
        if !value.isEnabled(for: key.bvid) {
            generation = UUID()
            syncGeneration = UUID()
            syncTask?.cancel(); syncTask = nil
            seekTask?.cancel(); seekTask = nil
            seekGeneration = UUID(); ownSeekTarget = nil
            submittedSeekID = nil
            completedSeek = nil
            removeObservers()
            setNotice(nil)
            syncState = .disabled
            // A per-video pause stops synchronization/skipping, but known
            // marks still make the toolbar's restore control discoverable.
            if value.enabled, !hasSnapshot { startSync(force: false) }
        } else if !wasEnabled {
            startSync(force: false)
        } else {
            configureTimeline()
            evaluate()
        }
    }

    func playbackStateChanged(allowed: Bool) {
        playbackAllowed = allowed
        if !allowed, submittedSeekID == nil {
            seekGeneration = UUID()
            seekTask?.cancel(); seekTask = nil
            ownSeekTarget = nil
        }
        evaluate()
    }

    func refresh() {
        guard !offlineOnly, let key, configuration.isEnabled(for: key.bvid) else { return }
        startSync(force: true)
    }

    private func startSync(force: Bool) {
        syncTask?.cancel()
        syncGeneration = UUID()
        let syncID = syncGeneration
        let expected = generation
        guard let key, let player, let item else { return }
        let canSynchronize = configuration.isEnabled(for: key.bvid)
        if canSynchronize { installJumpObserver() }
        syncState = canSynchronize ? .loading : .disabled
        syncTask = Task { [weak self, repository, offlineDirectories, offlineOnly] in
            var cached = await repository.cached(key)
            for directory in offlineDirectories {
                if let pinned = await repository.cached(key, offlineDirectory: directory),
                   cached == nil || pinned.fetchedAt > cached!.fetchedAt { cached = pinned }
            }
            guard let self, self.matches(expected, player: player, item: item), self.syncGeneration == syncID, !Task.isCancelled else { return }
            if let cached {
                self.apply(cached)
                self.syncState = canSynchronize ? (offlineOnly ? .offline : (cached.segments.isEmpty ? .empty : .ready)) : .disabled
            }
            guard canSynchronize else { return }
            if offlineOnly {
                if cached == nil { self.syncState = .offlineEmpty }
                return
            }
            if !force, let cached, cached.isFresh(at: Date()) {
                for directory in offlineDirectories { await repository.pin(cached, to: directory) }
                return
            }
            do {
                let result = try await repository.refresh(key, force: force)
                guard self.matches(expected, player: player, item: item), self.syncGeneration == syncID, !Task.isCancelled else { return }
                self.apply(result)
                self.syncState = result.segments.isEmpty ? .empty : .ready
                for directory in offlineDirectories { await repository.pin(result, to: directory) }
            } catch {
                guard self.matches(expected, player: player, item: item), self.syncGeneration == syncID, !Task.isCancelled else { return }
                self.syncState = self.hasSnapshot ? .cachedFailure : .failed
            }
        }
    }

    private func matches(_ expected: UUID, player: AVPlayer, item: AVPlayerItem) -> Bool {
        generation == expected && self.player === player && self.item === item && player.currentItem === item
    }

    private func apply(_ snapshot: SponsorSnapshot) {
        guard snapshot.key == key, let item else { return }
        let valid = snapshot.segments.filter { $0.isValid(for: snapshot.key, duration: item.duration.seconds) }
        if segments != valid { segments = valid }
        fetchedAt = snapshot.fetchedAt
        hasSnapshot = true
        configureTimeline()
        evaluate()
    }

    private func configureTimeline() {
        timeline.configure(segments: segments, configuration: configuration)
        if let lastUserSeekPosition { timeline.seekedByUser(to: lastUserSeekPosition) }
        armBoundaryObserver()
    }

    private func armBoundaryObserver() {
        removeBoundaryObserver()
        guard let player, let item, let key, configuration.isEnabled(for: key.bvid), !segments.isEmpty else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        let expected = generation
        let boundaryID = boundaryGeneration
        // Round forward so the boundary callback never evaluates a playhead
        // still just before the fractional segment start. Re-arm after seeks:
        // AVPlayer may coalesce callbacks while jumping over multiple times.
        let times = timeline.boundaries.filter { $0 > seconds }
            .map { NSValue(time: forwardTime($0, duration: item.duration)) }
        if !times.isEmpty {
            boundaryToken = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self, weak player, weak item] in
                MainActor.assumeIsolated {
                    guard let self, let player, let item, self.matches(expected, player: player, item: item),
                          self.boundaryGeneration == boundaryID else { return }
                    self.evaluate()
                }
            }
        }
    }

    private func installJumpObserver() {
        if let jumpToken { NotificationCenter.default.removeObserver(jumpToken) }
        jumpToken = nil
        guard let player, let item else { return }
        let expected = generation
        jumpToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: nil) { [weak self, weak player, weak item] _ in
            // Capture the emitted position before hopping to the main actor;
            // reading it later can mistake an old event for a newer user seek.
            let seconds = player?.currentTime().seconds ?? .nan
            let emittedAt = DispatchTime.now().uptimeNanoseconds
            let deliver = { @MainActor [weak self, weak player, weak item] in
                guard let self, let player, let item, self.matches(expected, player: player, item: item) else { return }
                // A newer command (notably undo) supersedes notifications
                // already emitted on another thread but awaiting this actor.
                guard emittedAt >= self.seekEventWatermark else { return }
                self.seekEventWatermark = emittedAt
                guard seconds.isFinite else { return }
                if let target = self.ownSeekTarget, abs(seconds - target) < 0.05 { return }
                if let completed = self.completedSeek, self.now() < completed.expiresAt,
                   abs(seconds - completed.target) < 0.05 { return }
                self.completedSeek = nil
                if let initial = self.initialPosition,
                   self.now() - self.initialPositionRecordedAt < 0.5,
                   abs(seconds - initial) < 0.1 {
                    self.initialPosition = nil
                    return
                }
                self.initialPosition = nil
                self.recordUserSeek(to: seconds)
                self.armBoundaryObserver()
                self.evaluate()
            }
            if Thread.isMainThread { MainActor.assumeIsolated { deliver() } }
            else { Task { @MainActor in deliver() } }
        }
    }

    private func removeObservers() {
        removeBoundaryObserver()
        if let jumpToken { NotificationCenter.default.removeObserver(jumpToken) }
        jumpToken = nil
    }

    private func removeBoundaryObserver() {
        boundaryGeneration = UUID()
        if let boundaryToken, let player { player.removeTimeObserver(boundaryToken) }
        boundaryToken = nil
    }

    private func evaluate() {
        guard let player, let item, player.currentItem === item, let key,
              configuration.isEnabled(for: key.bvid), playbackAllowed else { setNotice(nil); return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, ownSeekTarget == nil else { return }
        if let initialPosition, abs(seconds - initialPosition) >= 0.1
            || now() - initialPositionRecordedAt >= 0.5 {
            self.initialPosition = nil
        }
        if let lastUserSeekPosition,
           let pass = timeline.automatic.first(where: { $0.contains(lastUserSeekPosition) }),
           !pass.contains(seconds) { self.lastUserSeekPosition = nil }
        timeline.updatePass(at: seconds)
        let manual = timeline.manualInterval(at: seconds)
        dismissedManualIDs.formIntersection(manual?.ids ?? [])
        if player.timeControlStatus == .playing, let interval = timeline.automaticInterval(at: seconds) {
            seek(to: interval.end, automatic: interval, from: seconds)
        } else if case .skipped = notice {
            // Keep the short undo affordance until it expires or the user seeks.
        } else {
            setNotice(manual.flatMap { $0.ids.isDisjoint(with: dismissedManualIDs) ? .manual($0) : nil })
        }
    }

    func performNoticeAction() {
        let visibleNotice = notice
        updateNoticeCountdown()
        guard let notice, notice == visibleNotice else { return }
        switch notice {
        case .manual(let interval):
            guard let player, interval.contains(player.currentTime().seconds) else {
                setNotice(nil)
                evaluate()
                return
            }
            seek(to: interval.end)
        case .skipped(_, let from, _):
            userWillSeek(to: from)
            seek(to: from)
        }
    }

    func preview(_ segment: SponsorSegment) {
        guard isCurrentSegment(segment) else { return }
        userWillSeek(to: segment.start)
        seek(to: segment.start)
    }

    func skip(_ segment: SponsorSegment) {
        guard isCurrentSegment(segment) else { return }
        seek(to: segment.end)
    }

    private func isCurrentSegment(_ segment: SponsorSegment) -> Bool {
        guard let key, let item else { return false }
        return segments.contains(segment) && segment.isValid(for: key, duration: item.duration.seconds)
    }

    func userWillSeek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        seekEventWatermark = DispatchTime.now().uptimeNanoseconds
        recordUserSeek(to: seconds)
    }

    private func recordUserSeek(to seconds: Double) {
        seekGeneration = UUID()
        seekTask?.cancel(); seekTask = nil
        ownSeekTarget = nil
        submittedSeekID = nil
        completedSeek = nil
        initialPosition = nil
        lastUserSeekPosition = seconds
        timeline.seekedByUser(to: seconds)
        dismissedManualIDs = []
        setNotice(nil)
    }

    /// Native replay is a new pass, unlike deliberately scrubbing into a mark.
    func playbackWillRestart(player: AVPlayer, item: AVPlayerItem) -> UUID? {
        guard self.player === player, self.item === item, let key,
              configuration.isEnabled(for: key.bvid) else { return nil }
        seekEventWatermark = DispatchTime.now().uptimeNanoseconds
        seekGeneration = UUID()
        seekTask?.cancel(); seekTask = nil
        ownSeekTarget = 0
        submittedSeekID = seekGeneration
        completedSeek = nil
        initialPosition = nil
        lastUserSeekPosition = nil
        dismissedManualIDs = []
        timeline = SponsorTimeline()
        timeline.configure(segments: segments, configuration: configuration)
        removeBoundaryObserver()
        setNotice(nil)
        return seekGeneration
    }

    func playbackDidRestart(_ restartID: UUID, completed: Bool) {
        guard seekGeneration == restartID else { return }
        ownSeekTarget = nil
        submittedSeekID = nil
        completedSeek = completed ? (0, now() + 1) : nil
        armBoundaryObserver()
        evaluate()
    }

    private func seek(to target: Double, automatic: SponsorInterval? = nil, from: Double = 0) {
        guard playbackAllowed, let key, configuration.isEnabled(for: key.bvid),
              let player, let item, player.currentItem === item,
              target.isFinite, target >= 0, target <= item.duration.seconds else { return }
        let expected = generation
        seekEventWatermark = DispatchTime.now().uptimeNanoseconds
        let seekTime = automatic != nil || target > player.currentTime().seconds
            ? forwardTime(target, duration: item.duration)
            : CMTime(seconds: target, preferredTimescale: 600_000)
        let resolvedTarget = seekTime.seconds
        let seekID = UUID()
        seekGeneration = seekID
        submittedSeekID = nil
        ownSeekTarget = resolvedTarget
        seekTask?.cancel()
        // AVPlayer.seek retains its current playback rate; we never issue play
        // here, so a pause or navigation event during a seek stays authoritative.
        seekTask = Task { [weak self, weak player, weak item] in
            guard !Task.isCancelled, let self, let player, let item,
                  self.matches(expected, player: player, item: item),
                  self.seekGeneration == seekID, self.playbackAllowed,
                  self.configuration.isEnabled(for: key.bvid) else { return }
            if let automatic, player.timeControlStatus != .playing
                || !automatic.contains(player.currentTime().seconds)
                || self.timeline.automaticInterval(at: from)?.ids != automatic.ids {
                self.ownSeekTarget = nil
                self.seekTask = nil
                self.evaluate()
                return
            }
            self.initialPosition = nil
            let actualFrom = player.currentTime().seconds
            self.submittedSeekID = seekID
            let completed = await player.seek(to: seekTime,
                                              toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.matches(expected, player: player, item: item), self.seekGeneration == seekID else { return }
            self.ownSeekTarget = nil
            self.submittedSeekID = nil
            self.seekTask = nil
            // Completion and time-jump notifications have no guaranteed order.
            // Keep the receipt briefly to acknowledge late/duplicate managed
            // jumps without turning them into user seeks or removing undo.
            self.completedSeek = completed ? (resolvedTarget, self.now() + 1) : nil
            self.armBoundaryObserver()
            self.timeline.updatePass(at: player.currentTime().seconds)
            let didLeaveInterval = automatic.map { player.currentTime().seconds >= $0.end } ?? completed
            if completed, didLeaveInterval, let automatic, self.playbackAllowed, self.configuration.showsNotification {
                self.setNotice(.skipped(label: automatic.label, from: actualFrom, interval: automatic))
                self.evaluate()
            } else {
                if (!completed || !didLeaveInterval), automatic != nil {
                    self.lastUserSeekPosition = actualFrom
                    self.timeline.seekedByUser(to: actualFrom)
                }
                self.setNotice(nil)
                self.evaluate()
            }
        }
    }

    private func setNotice(_ value: SponsorNotice?) {
        guard notice != value else { return }
        noticeTask?.cancel(); noticeTask = nil
        noticeGeneration = UUID()
        let noticeID = noticeGeneration
        notice = value
        noticeDeadline = value == nil ? nil : now() + Self.noticeDuration
        noticeSecondsRemaining = value == nil ? 0 : Int(Self.noticeDuration)
        guard value != nil else { return }
        noticeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.noticeGeneration == noticeID else { return }
                self.updateNoticeCountdown()
                if self.notice == nil { return }
            }
        }
    }

    func updateNoticeCountdown() {
        guard let deadline = noticeDeadline, let notice else { return }
        let remaining = max(0, Int(ceil(deadline - now())))
        if noticeSecondsRemaining != remaining { noticeSecondsRemaining = remaining }
        guard remaining == 0 else { return }
        if case .manual(let interval) = notice { dismissedManualIDs.formUnion(interval.ids) }
        setNotice(nil)
        evaluate()
    }

    private func forwardTime(_ seconds: Double, duration: CMTime) -> CMTime {
        let scale: CMTimeScale = 60_000
        // Construct ticks directly. Dividing back to Double and using
        // CMTime(seconds:) truncates again (32.876 becomes 32.875983).
        let time = CMTime(value: Int64(ceil(seconds * Double(scale))), timescale: scale)
        return CMTimeCompare(time, duration) > 0 ? duration : time
    }

    func waitForSynchronization() async { await syncTask?.value }
}
