import Foundation

@MainActor
final class LiveDanmakuStream: NSObject, URLSessionWebSocketDelegate {
    private let roomID: Int64
    private let selfMID: Int64
    private let onDanmaku: ([LiveDanmakuParser.Event]) -> Void
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pendingEvents: [LiveDanmakuParser.Event] = []
    private var flushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var isClosed = false
    private var sequence: Int32 = 1

    init(
        roomID: Int64,
        selfMID: Int64,
        onDanmaku: @escaping ([LiveDanmakuParser.Event]) -> Void
    ) {
        self.roomID = roomID
        self.selfMID = selfMID
        self.onDanmaku = onDanmaku
    }

    func start() async {
        close()
        startGeneration &+= 1
        let generation = startGeneration
        isClosed = false
        do {
            let info = try await CoreClient.shared.perform(priority: .utility) { [roomID] core in
                try core.liveDanmakuInfo(roomID: roomID)
            }
            guard !isClosed, generation == startGeneration else { return }
            guard let server = info.hostList.first(where: { $0.wssPort > 0 }) ?? info.hostList.first,
                  !server.host.isEmpty else {
                return
            }
            let port = server.wssPort > 0 ? server.wssPort : (server.wsPort > 0 ? server.wsPort : server.port)
            let scheme = server.wssPort > 0 ? "wss" : "ws"
            guard let url = URL(string: "\(scheme)://\(server.host):\(port)/sub") else { return }

            let configuration = URLSessionConfiguration.default
            configuration.httpAdditionalHeaders = [
                "User-Agent": BiliHTTP.userAgent,
                "Origin": "https://live.bilibili.com",
                "Referer": "https://live.bilibili.com/\(roomID)"
            ]
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url)
            self.session = session
            self.task = task
            task.resume()
            sendAuth(token: info.token)
            receiveLoop()
        } catch {
            AppLog.error("live", "直播弹幕连接初始化失败", error: error, metadata: [
                "roomID": String(roomID)
            ])
        }
    }

    func close() {
        startGeneration &+= 1
        isClosed = true
        flushTask?.cancel()
        flushTask = nil
        pendingEvents.removeAll()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    deinit {
        MainActor.assumeIsolated {
            close()
        }
    }

    private func sendAuth(token: String) {
        let payload: [String: Any] = [
            "roomid": roomID,
            "uid": selfMID,
            "protover": 3,
            "platform": "web",
            "type": 2,
            "key": token
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        sendPacket(operation: 7, body: body)
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    guard let self, !self.isClosed else { return }
                    self.sendPacket(operation: 2, body: Data())
                }
            }
        }
    }

    private func sendPacket(operation: Int32, body: Data) {
        guard !isClosed else { return }
        var packet = Data(capacity: 16 + body.count)
        packet.appendUInt32BE(UInt32(16 + body.count))
        packet.appendUInt16BE(16)
        packet.appendUInt16BE(1)
        packet.appendUInt32BE(UInt32(bitPattern: operation))
        packet.appendUInt32BE(UInt32(bitPattern: sequence))
        sequence += 1
        packet.append(body)
        task?.send(.data(packet)) { error in
            if let error {
                Task { @MainActor in
                    AppLog.error("live", "直播弹幕包发送失败", error: error, metadata: [
                        "roomID": String(self.roomID)
                    ])
                }
            }
        }
    }

    private func receiveLoop() {
        guard let socket = task else { return }
        let generation = startGeneration
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.startGeneration == generation, self.task === socket else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    let json: Bool
                    switch message {
                    case .data(let value): data = value; json = false
                    case .string(let value): data = Data(value.utf8); json = true
                    @unknown default: self.receiveLoop(); return
                    }
                    let roomID = self.roomID
                    let selfMID = self.selfMID
                    let batch = try? await BlockingWorkQueue.live.run(priority: .utility) {
                        var parser = LiveDanmakuParser(roomID: roomID, selfMID: selfMID)
                        return parser.decode(data, json: json)
                    }
                    guard !self.isClosed, self.startGeneration == generation, self.task === socket else { return }
                    if let batch {
                        if batch.authenticated { self.startHeartbeat() }
                        self.enqueue(batch.events)
                    }
                    self.receiveLoop()
                case .failure(let error):
                    self.flushPendingEvents()
                    AppLog.error("live", "直播弹幕连接断开", error: error, metadata: ["roomID": String(self.roomID)])
                    self.close()
                }
            }
        }
    }

    private func enqueue(_ events: [LiveDanmakuParser.Event]) {
        guard !events.isEmpty else { return }
        pendingEvents.append(contentsOf: events)
        if pendingEvents.count > 1000 { pendingEvents.removeFirst(pendingEvents.count - 1000) }
        guard flushTask == nil else { return }
        let generation = startGeneration
        flushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, !self.isClosed, self.startGeneration == generation else { return }
            self.flushPendingEvents()
        }
    }

    private func flushPendingEvents() {
        flushTask?.cancel()
        flushTask = nil
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        if !events.isEmpty { onDanmaku(events) }
    }
}
