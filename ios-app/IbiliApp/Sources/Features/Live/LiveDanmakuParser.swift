import Compression
import Foundation

struct LiveDanmakuParser {
    struct Event { let item: DanmakuItemDTO; let message: LiveDanmakuMessageDTO }
    struct Batch { var authenticated = false; var events: [Event] = [] }
    let roomID: Int64
    let selfMID: Int64
    private var batch = Batch()

    init(roomID: Int64, selfMID: Int64) { self.roomID = roomID; self.selfMID = selfMID }

    mutating func decode(_ data: Data, json: Bool = false) -> Batch {
        batch = Batch()
        guard data.count <= 4 * 1024 * 1024 else { return batch }
        if json { processMessageData(data) } else { processPacket(data) }
        if batch.events.count > 1000 { batch.events.removeFirst(batch.events.count - 1000) }
        return batch
    }

    private mutating func processPacket(_ data: Data, depth: Int = 0) {
        guard depth < 5, data.count <= 4 * 1024 * 1024 else { return }
        var offset = 0
        while offset + 16 <= data.count {
            let totalSize = Int(data.readUInt32BE(at: offset))
            let headerSize = Int(data.readUInt16BE(at: offset + 4))
            let protocolVersion = Int(data.readUInt16BE(at: offset + 6))
            let operation = Int(data.readUInt32BE(at: offset + 8))
            guard headerSize >= 16, totalSize >= headerSize, offset + totalSize <= data.count else { break }
            let body = data.subdata(in: (offset + headerSize)..<(offset + totalSize))

            switch operation {
            case 8:
                batch.authenticated = true
            case 3:
                break
            default:
                switch protocolVersion {
                case 0, 1:
                    processMessageData(body)
                case 2:
                    if let inflated = body.inflateZlib() {
                        processPacket(inflated, depth: depth + 1)
                    }
                case 3:
                    if let decoded = body.decompressBrotli() {
                        processPacket(decoded, depth: depth + 1)
                    }
                default:
                    break
                }
            }
            offset += totalSize
        }
    }

    private mutating func processMessageData(_ data: Data) {
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

    private mutating func processObject(_ object: Any) {
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
        var emotes: [ReplyEmoteDTO] = []

        if let extra = parseLiveDanmakuExtra(from: first) {
            if let v = extra["mode"] as? NSNumber { mode = v.int32Value }
            if let v = extra["color"] as? NSNumber { color = v.uint32Value }
            if let id = extra["id_str"] as? String, !id.isEmpty { messageID = id }
            emotes.append(contentsOf: parseInlineEmotes(from: extra["emots"]))
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
        if let single = parseSingleEmote(from: first?[safe: 13], fallbackName: text) {
            emotes.append(single)
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

        if batch.events.count >= 2000 { batch.events.removeFirst(1000) }
        let isSelf = selfMID > 0 && senderMID == selfMID
        batch.events.append(Event(item: DanmakuItemDTO(
            timeSec: 0,
            mode: mode,
            color: color,
            fontSize: fontSize,
            text: text,
            isSelf: isSelf
        ), message: LiveDanmakuMessageDTO(
            id: messageID,
            uid: senderMID,
            name: senderName,
            text: text,
            isSelf: isSelf,
            emotes: deduplicatedEmotes(emotes)
        )))
    }

    private func parseInlineEmotes(from raw: Any?) -> [ReplyEmoteDTO] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.compactMap { key, value in
            parseSingleEmote(from: value, fallbackName: key)
        }
    }

    private func parseSingleEmote(from raw: Any?, fallbackName: String) -> ReplyEmoteDTO? {
        guard let dict = raw as? [String: Any] else { return nil }
        let url = normalizedImageURL(dict["url"] as? String ?? "")
        guard !url.isEmpty else { return nil }
        let name = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let width = numericDouble(dict["width"]) ?? 0
        let height = numericDouble(dict["height"]) ?? width
        let size: Int32 = max(width, height) >= 80 ? 2 : 1
        return ReplyEmoteDTO(name: name, url: url, size: size)
    }

    private func deduplicatedEmotes(_ emotes: [ReplyEmoteDTO]) -> [ReplyEmoteDTO] {
        var seen = Set<String>()
        var result: [ReplyEmoteDTO] = []
        for emote in emotes where seen.insert(emote.name).inserted {
            result.append(emote)
        }
        return result
    }

    private func normalizedImageURL(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:\(raw)" }
        if raw.hasPrefix("http://") { return "https://" + String(raw.dropFirst("http://".count)) }
        return raw
    }

    private func numericDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
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

extension Data {
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
                guard output.count + destinationSize - stream.dst_size <= 4 * 1024 * 1024 else { return nil }
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
