import Foundation

enum SponsorCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sponsor, selfpromo, interaction, intro, outro, preview, padding, filler, music_offtopic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sponsor: return "赞助广告"
        case .selfpromo: return "自我推广"
        case .interaction: return "求赞、关注等互动"
        case .intro: return "开场"
        case .outro: return "结尾"
        case .preview: return "预告与回顾"
        case .padding: return "无内容片段"
        case .filler: return "离题闲聊"
        case .music_offtopic: return "音乐中的非音乐片段"
        }
    }
    var defaultPolicy: SponsorSkipPolicy {
        switch self {
        case .sponsor: return .automatic
        case .interaction, .intro, .outro: return .manual
        default: return .disabled
        }
    }
}

enum SponsorSkipPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, manual, disabled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "自动跳过"
        case .manual: return "手动跳过"
        case .disabled: return "关闭"
        }
    }
}

struct SponsorConfiguration: Equatable, Sendable {
    var enabled = true
    var showsNotification = true
    var policies: [SponsorCategory: SponsorSkipPolicy] = [:]
    var disabledVideos: Set<String> = []
    func policy(for category: SponsorCategory) -> SponsorSkipPolicy {
        policies[category] ?? category.defaultPolicy
    }
    func isEnabled(for bvid: String) -> Bool { enabled && !disabledVideos.contains(bvid) }
}

struct SponsorVideoKey: Codable, Hashable, Sendable {
    let bvid: String
    let cid: Int64
    var isValid: Bool {
        cid > 0 && bvid.count == 12 && bvid.hasPrefix("BV")
            && bvid.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    var fileName: String { "\(bvid)-\(cid).json" }
}

struct SponsorSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let cid: Int64
    let category: SponsorCategory
    let start: Double
    let end: Double
    let videoDuration: Double
    enum CodingKeys: String, CodingKey {
        case id, cid, category, start, end
        case videoDuration = "video_duration"
    }
    func isValid(for key: SponsorVideoKey, duration: Double) -> Bool {
        cid == key.cid && !id.isEmpty && start.isFinite && end.isFinite
            && start >= 0 && end > start && duration.isFinite && duration > 0 && end <= duration
            && videoDuration.isFinite && videoDuration >= 0
            && (videoDuration == 0 || abs(duration - videoDuration) <= 2)
    }
    func contains(_ seconds: Double) -> Bool { seconds >= start && seconds < end }
    var timeLabel: String { "\(Self.timeLabel(start)) – \(Self.timeLabel(end))" }
    static func timeLabel(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%04.1f", Int(value / 60), value.truncatingRemainder(dividingBy: 60))
    }
}

struct SponsorSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let key: SponsorVideoKey
    let fetchedAt: Date
    let segments: [SponsorSegment]
    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(fetchedAt)
        return age >= 0 && age < (segments.isEmpty ? 15 * 60 : 60 * 60)
    }
}

struct SponsorInterval: Equatable {
    var start: Double
    var end: Double
    var segments: [SponsorSegment]
    var ids: Set<String> { Set(segments.map(\.id)) }
    func contains(_ seconds: Double) -> Bool { seconds >= start && seconds < end }
    var label: String { segments.first?.category.label ?? "标记片段" }
}

/// A playback pass ends when the playhead leaves an interval. Explicit seeks and
/// undo suppress only that pass, so a later replay can skip normally again.
struct SponsorTimeline {
    private(set) var automatic: [SponsorInterval] = []
    private(set) var manual: [SponsorInterval] = []
    private(set) var suppressed: Set<String> = []

    mutating func configure(segments: [SponsorSegment], configuration: SponsorConfiguration) {
        automatic = []
        manual = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let interval = SponsorInterval(start: segment.start, end: segment.end, segments: [segment])
            switch configuration.policy(for: segment.category) {
            case .automatic:
                if let last = automatic.last, interval.start <= last.end {
                    automatic[automatic.count - 1].end = max(last.end, interval.end)
                    automatic[automatic.count - 1].segments.append(segment)
                } else { automatic.append(interval) }
            case .manual: manual.append(interval)
            case .disabled: break
            }
        }
        suppressed.formIntersection(Set(segments.map(\.id)))
    }

    mutating func seekedByUser(to seconds: Double) {
        suppressed.formUnion(automatic.filter { $0.contains(seconds) }.flatMap { $0.ids })
    }

    mutating func updatePass(at seconds: Double) {
        let current = Set(automatic.filter { $0.contains(seconds) }.flatMap { $0.ids })
        suppressed.formIntersection(current)
    }

    func automaticInterval(at seconds: Double) -> SponsorInterval? {
        automatic.first { $0.contains(seconds) && $0.ids.isDisjoint(with: suppressed) }
    }

    func manualInterval(at seconds: Double) -> SponsorInterval? {
        let candidates = manual + automatic.filter { !$0.ids.isDisjoint(with: suppressed) }
        return candidates.filter { $0.contains(seconds) }.max { $0.end < $1.end }
    }

    var boundaries: [Double] {
        Array(Set((automatic + manual).flatMap { [$0.start, $0.end] })).sorted()
    }
}
