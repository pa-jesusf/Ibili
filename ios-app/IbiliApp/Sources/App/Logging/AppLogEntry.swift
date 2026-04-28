import Foundation

enum AppLogLevel: String, Codable, CaseIterable, Hashable {
    case debug
    case info
    case warning
    case error

    var title: String {
        switch self {
        case .debug: return "调试"
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

struct AppLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: AppLogLevel
    let category: String
    let message: String
    let metadata: [String: String]

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         level: AppLogLevel,
         category: String,
         message: String,
         metadata: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    var sortedMetadata: [(String, String)] {
        metadata.keys.sorted().map { ($0, metadata[$0] ?? "") }
    }

    var formattedLine: String {
        let prefix = "\(Self.timestampFormatter.string(from: timestamp)) [\(level.rawValue.uppercased())] [\(category)] \(message)"
        guard !metadata.isEmpty else { return prefix }
        let tail = sortedMetadata
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: " ")
        return "\(prefix) | \(tail)"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}