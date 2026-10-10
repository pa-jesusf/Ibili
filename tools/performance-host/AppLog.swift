import Foundation

// The host regression runner compiles the production request code unchanged.
// Only its unrelated log sink is replaced, so tests never write user app logs.
enum AppLog {
    static func info(_ category: String, _ message: String, metadata: [String: String] = [:]) {}
    static func warning(_ category: String, _ message: String, metadata: [String: String] = [:]) {}
    static func error(_ category: String, _ message: String, error: Error? = nil,
                      metadata: [String: String] = [:]) {}
}
