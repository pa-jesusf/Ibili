import Compression
import Foundation

@MainActor
final class LiveDanmakuStream: NSObject, URLSessionWebSocketDelegate {
    private let roomID: Int64
    private let selfMID: Int64
    private let onDanmaku: (DanmakuItemDTO, LiveDanmakuMessageDTO) -> Void
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTask: Task<Void, Never>?
    private var isClosed = false
    private var sequence: Int32 = 1

    init(
        roomID: Int64,
        selfMID: Int64,
        onDanmaku: @escaping (DanmakuItemDTO, LiveDanmakuMessageDTO) -> Void
    ) {
        self.roomID = roomID
        self.selfMID = selfMID
        self.onDanmaku = onDanmaku
    }

    func start() async {
        close()
        isClosed = false
        do {
            let info = try await Task.detached(priority: .utility) { [roomID] in
                try CoreClient.shared.liveDanmakuInfo(roomID: roomID)
            }.value
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
        isClosed = true
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
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.processPacket(data)
                    case .string(let string):
                        if let data = string.data(using: .utf8) {
                            self.processMessageData(data)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLoop()
                case .failure(let error):
                    AppLog.error("live", "直播弹幕连接断开", error: error, metadata: [
                        "roomID": String(self.roomID)
                    ])
                    self.close()
                }
            }
        }
    }

    private func processPacket(_ data: Data) {
        var offset = 0
        while offset + 16 <= data.count {
            let totalSize = Int(data.readUInt32BE(at: offset))
            let headerSize = Int(data.readUInt16BE(at: offset + 4))
            let protocolVersion = Int(data.readUInt16BE(at: offset + 6))
            let operation = Int(data.readUInt32BE(at: offset + 8))
            guard totalSize >= headerSize, offset + totalSize <= data.count else { break }
            let body = data.subdata(in: (offset + headerSize)..<(offset + totalSize))

            switch operation {
            case 8:
                startHeartbeat()
            case 3:
                break
            default:
                switch protocolVersion {
                case 0, 1:
                    processMessageData(body)
                case 2:
                    if let inflated = body.inflateZlib() {
                        processPacket(inflated)
                    }
                case 3:
                    if let decoded = body.decompressBrotli() {
                        processPacket(decoded)
                    }
                default:
                    break
                }
            }
            offset += totalSize
        }
    }

    private func processMessageData(_ data: Data) {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            processObject(object)
            return
        }
        if let string = String(data: data, encoding: .utf8) {
            for line in string.split(separator: "\0") {
                guard let chunk = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: chunk) else {
                    continue
                }
                processObject(object)
            }
        }
    }

    private func processObject(_ object: Any) {
        guard let dict = object as? [String: Any],
              let command = dict["cmd"] as? String,
              command.hasPrefix("DANMU_MSG"),
              let info = dict["info"] as? [Any],
              info.count > 1,
              let text = info[1] as? String,
              !text.isEmpty else {
            return
        }

        let first = info.first as? [Any]
        var mode: Int32 = 1
        var color: UInt32 = 16_777_215
        var fontSize: Int32 = 25
        var senderMID: Int64 = 0
        var senderName = ""
        var messageID = "live-\(roomID)-\(UUID().uuidString)"

        if let extra = parseLiveDanmakuExtra(from: first) {
            if let v = extra["mode"] as? NSNumber { mode = v.int32Value }
            if let v = extra["color"] as? NSNumber { color = v.uint32Value }
            if let id = extra["id_str"] as? String, !id.isEmpty { messageID = id }
            if let user = extra["user"] as? [String: Any],
               let uid = user["uid"] as? NSNumber {
                senderMID = uid.int64Value
            }
            if let user = extra["user"] as? [String: Any],
               let base = user["base"] as? [String: Any],
               let name = base["name"] as? String {
                senderName = name
            }
        }
        if let content = first?[safe: 15] as? [String: Any],
           let user = content["user"] as? [String: Any] {
            if senderMID == 0, let uid = user["uid"] as? NSNumber {
                senderMID = uid.int64Value
            }
            if senderName.isEmpty,
               let base = user["base"] as? [String: Any],
               let name = base["name"] as? String {
                senderName = name
            }
        }

        if let first {
            if mode == 1, let v = first[safe: 1] as? NSNumber { mode = v.int32Value }
            if fontSize == 25, let v = first[safe: 2] as? NSNumber { fontSize = v.int32Value }
            if color == 16_777_215, let v = first[safe: 3] as? NSNumber { color = v.uint32Value }
        }
        if senderMID == 0,
           let user = info[safe: 2] as? [Any],
           let uid = user.first as? NSNumber {
            senderMID = uid.int64Value
        }
        if senderName.isEmpty,
           let user = info[safe: 2] as? [Any],
           let name = user[safe: 1] as? String {
            senderName = name
        }

        let isSelf = selfMID > 0 && senderMID == selfMID
        onDanmaku(DanmakuItemDTO(
            timeSec: 0,
            mode: mode,
            color: color,
            fontSize: fontSize,
            text: text,
            isSelf: isSelf
        ), LiveDanmakuMessageDTO(
            id: messageID,
            uid: senderMID,
            name: senderName,
            text: text,
            isSelf: isSelf
        ))
    }

    private func parseLiveDanmakuExtra(from first: [Any]?) -> [String: Any]? {
        guard let first else { return nil }
        if let content = first[safe: 15] as? [String: Any],
           let raw = content["extra"] as? String,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        if let raw = first[safe: 15] as? String,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func inflateZlib() -> Data? {
        withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return streamDecompress(source: source, sourceSize: count, algorithm: COMPRESSION_ZLIB)
        }
    }

    func decompressBrotli() -> Data? {
        withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return streamDecompress(source: source, sourceSize: count, algorithm: COMPRESSION_BROTLI)
        }
    }

    private func streamDecompress(
        source: UnsafePointer<UInt8>,
        sourceSize: Int,
        algorithm: compression_algorithm
    ) -> Data? {
        let destinationSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destination.deallocate() }

        let emptyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let emptySrc = UnsafePointer(emptyDst)
        defer { emptyDst.deallocate() }
        var stream = compression_stream(
            dst_ptr: emptyDst,
            dst_size: 0,
            src_ptr: emptySrc,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        stream.src_ptr = source
        stream.src_size = sourceSize

        var output = Data()
        repeat {
            stream.dst_ptr = destination
            stream.dst_size = destinationSize
            let status = compression_stream_process(&stream, 0)
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                output.append(destination, count: destinationSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { return output }
            default:
                return nil
            }
        } while stream.src_size > 0
        return output
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
