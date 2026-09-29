import Foundation
import Network

/// Owns listener identity and shares startup across simultaneous player loads.
/// All waits suspend; only Network callbacks touch the socket queue.
actor HLSProxyListener {
    private let queue = DispatchQueue(label: "ibili.hls.listener", qos: .userInitiated)
    private var listener: NWListener?
    private var listenerID: UUID?
    private var readyPort: UInt16?
    private var readiness: CheckedContinuation<UInt16, Error>?
    private var deadline: Task<Void, Never>?
    private var startup: (id: UUID, task: Task<UInt16, Error>)?

    deinit { listener?.cancel(); deadline?.cancel() }

    func port(onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        if let startup { return try await startup.task.value }
        let id = UUID()
        let task = Task {
            if await isHealthy(), let readyPort { return readyPort }
            return try await start(onConnection: onConnection)
        }
        startup = (id, task)
        defer { if startup?.id == id { startup = nil } }
        return try await task.value
    }

    func isHealthy() async -> Bool {
        guard let id = listenerID, let port = readyPort, listener != nil else { return false }
        let healthy = await Self.probe(port: port)
        guard listenerID == id else { return false }
        if !healthy { invalidate() }
        return healthy
    }

    private func start(onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        invalidate()
        let candidate = try NWListener(using: .tcp, on: .any)
        let id = UUID()
        listener = candidate
        listenerID = id
        candidate.newConnectionHandler = onConnection
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            let port = candidate?.port?.rawValue
            Task { await self?.changed(state, port: port, id: id) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            readiness = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                await self?.timedOut(id)
            }
            candidate.start(queue: queue)
        }
    }

    private func changed(_ state: NWListener.State, port: UInt16?, id: UUID) {
        guard listenerID == id else { return }
        switch state {
        case .ready:
            guard let port else { return }
            readyPort = port
            deadline?.cancel()
            deadline = nil
            let continuation = readiness
            readiness = nil
            continuation?.resume(returning: port)
        case .failed(let error):
            invalidate(error: error)
        case .cancelled:
            invalidate()
        default: break
        }
    }

    private func timedOut(_ id: UUID) {
        guard listenerID == id, readiness != nil else { return }
        invalidate(error: URLError(.timedOut))
    }

    private func invalidate(error: Error = URLError(.networkConnectionLost)) {
        let stale = listener
        listener = nil
        listenerID = nil
        readyPort = nil
        deadline?.cancel()
        deadline = nil
        let continuation = readiness
        readiness = nil
        stale?.cancel()
        continuation?.resume(throwing: error)
    }

    private nonisolated static func probe(port: UInt16) async -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        let queue = DispatchQueue.global(qos: .userInitiated)
        return await withCheckedContinuation { continuation in
            let completion = ProbeCompletion(continuation)
            let finish: @Sendable (Bool) -> Void = { success in
                guard completion.finish(success) else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.2) { finish(false) }
        }
    }

    private final class ProbeCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ success: Bool) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: success)
            return pending != nil
        }
    }
}
