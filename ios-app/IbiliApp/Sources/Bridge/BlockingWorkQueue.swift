import Foundation

/// Blocking FFI and image decoding must not occupy Swift's cooperative executor.
/// A cancelled operation keeps its slot until the actual blocking work finishes.
final class BlockingWorkQueue: @unchecked Sendable {
    static let core = BlockingWorkQueue(name: "ibili.core.requests", concurrency: 4)
    static let images = BlockingWorkQueue(name: "ibili.image.decode", concurrency: 2)
    private let queue: OperationQueue

    init(name: String, concurrency: Int) {
        queue = OperationQueue()
        queue.name = name
        queue.maxConcurrentOperationCount = max(1, concurrency)
        queue.qualityOfService = .userInitiated
    }

    func run<T>(priority: TaskPriority = .userInitiated,
                _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let operation = BlockOperation {
                    do {
                        try cancellation.check()
                        let result = try work()
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                operation.queuePriority = priority >= .userInitiated ? .high : .low
                operation.qualityOfService = priority >= .userInitiated ? .userInitiated : .utility
                queue.addOperation(operation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock()
            let value = cancelled
            lock.unlock()
            if value { throw CancellationError() }
        }
    }
}
