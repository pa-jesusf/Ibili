import Foundation

/// Bounded, fixed-window coalescing before either the UI or disk sees a log.
/// Preserve the first sample and count, including interleaved noisy producers.
struct AppLogCoalescer {
    private struct Sample {
        let entry: AppLogEntry
        let signature: String
        var suppressed = 0
    }
    private var samples: [String: Sample] = [:]
    private let window: TimeInterval = 2
    private let capacity = 128

    var hasPendingSummary: Bool { samples.values.contains { $0.suppressed > 0 } }

    mutating func append(_ entry: AppLogEntry) -> [AppLogEntry] {
        var output = flush(at: entry.timestamp)
        guard let signature = signature(entry) else { return output + [entry] }
        let source = entry.category + "\u{1f}" + entry.message
        if let previous = samples[source] {
            if previous.signature == signature {
                samples[source]!.suppressed += 1
                return output
            }
            // A → B → A is a new transition, not a repeat of the first A.
            if let summary = summary(previous, at: entry.timestamp) { output.append(summary) }
            samples.removeValue(forKey: source)
        }
        if samples.count >= capacity, let oldest = samples.min(by: { $0.value.entry.timestamp < $1.value.entry.timestamp }) {
            if let summary = summary(oldest.value, at: entry.timestamp) { output.append(summary) }
            samples.removeValue(forKey: oldest.key)
        }
        samples[source] = Sample(entry: entry, signature: signature)
        return output + [entry]
    }

    mutating func flush(at date: Date, force: Bool = false) -> [AppLogEntry] {
        var output: [AppLogEntry] = []
        for (key, sample) in samples where force || date.timeIntervalSince(sample.entry.timestamp) >= window {
            if let summary = summary(sample, at: date) { output.append(summary) }
            samples.removeValue(forKey: key)
        }
        return output.sorted { $0.message < $1.message }
    }

    private func signature(_ entry: AppLogEntry) -> String? {
        guard entry.level == .debug, ["player", "navigation", "danmaku"].contains(entry.category) else { return nil }
        let volatile: Set<String> = ["callStack", "point", "traceAgeMs", "transientPauseSuppressionRemainingMs"]
        // Session/content IDs and user-action traceID remain part of the key.
        // A different video, command, state, or interaction is a new fact.
        let metadata = entry.metadata.filter { !volatile.contains($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = (try? encoder.encode(metadata)) ?? Data()
        return entry.category + "\u{1f}" + entry.message + "\u{1f}" + encoded.base64EncodedString()
    }

    private func summary(_ sample: Sample, at date: Date) -> AppLogEntry? {
        guard sample.suppressed > 0 else { return nil }
        var metadata = sample.entry.metadata.filter { $0.key != "callStack" && $0.key != "point" }
        metadata["originalMessage"] = sample.entry.message
        metadata["suppressedCount"] = String(sample.suppressed)
        return AppLogEntry(timestamp: date, level: .debug, category: sample.entry.category,
                           message: "重复调试日志已合并", metadata: metadata)
    }
}
