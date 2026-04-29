import CoreGraphics
import Foundation

/// Best-effort parser for Bilibili mode-7 special danmaku.
/// We intentionally support the common subset first: text, start/end
/// position, alpha range, delay, and move duration. Rotation, path motion,
/// and other advanced fields can be layered on later without entangling the
/// main canvas renderer.
struct SpecialDanmakuDescriptor {
    let text: String
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let startAlpha: CGFloat
    let endAlpha: CGFloat
    let delay: Double
    let moveDuration: Double
    let displayDuration: Double

    private static let legacyStageSize = CGSize(width: 682, height: 438)

    static func parse(rawText: String) -> SpecialDanmakuDescriptor? {
        let sanitized = rawText.replacingOccurrences(of: "\n", with: "\\n")
        guard let data = sanitized.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any],
              payload.count >= 5 else { return nil }

        let parsedText = stringValue(payload[safe: 4])?
            .replacingOccurrences(of: "/n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = parsedText, !text.isEmpty else { return nil }

        let startX = CGFloat(scalarValue(payload[safe: 0]) ?? 0)
        let startY = CGFloat(scalarValue(payload[safe: 1]) ?? 0)
        let (startAlpha, endAlpha) = alphaRange(from: payload[safe: 2])
        let baseDuration = max(scalarValue(payload[safe: 3]) ?? 4.0, 0.1)
        let endX = CGFloat(scalarValue(payload[safe: 7]) ?? Double(startX))
        let endY = CGFloat(scalarValue(payload[safe: 8]) ?? Double(startY))
        let moveDuration = max((scalarValue(payload[safe: 9]) ?? (baseDuration * 1000.0)) / 1000.0, 0.1)
        let delay = max((scalarValue(payload[safe: 10]) ?? 0) / 1000.0, 0)

        return SpecialDanmakuDescriptor(
            text: text,
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            startAlpha: startAlpha,
            endAlpha: endAlpha,
            delay: delay,
            moveDuration: moveDuration,
            displayDuration: max(baseDuration, delay + moveDuration)
        )
    }

    func position(at elapsed: Double, in size: CGSize) -> CGPoint {
        let progress = motionProgress(at: elapsed)
        let start = CGPoint(
            x: resolveCoordinate(startX, axis: .x, in: size),
            y: resolveCoordinate(startY, axis: .y, in: size)
        )
        let end = CGPoint(
            x: resolveCoordinate(endX, axis: .x, in: size),
            y: resolveCoordinate(endY, axis: .y, in: size)
        )
        return CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    func alpha(at elapsed: Double) -> CGFloat {
        guard elapsed >= delay else { return 0 }
        let progress = motionProgress(at: elapsed)
        return startAlpha + (endAlpha - startAlpha) * progress
    }

    private func motionProgress(at elapsed: Double) -> CGFloat {
        guard elapsed >= delay else { return 0 }
        let motionElapsed = min(max(elapsed - delay, 0), moveDuration)
        return CGFloat(motionElapsed / moveDuration)
    }

    private enum Axis { case x, y }

    private func resolveCoordinate(_ raw: CGFloat, axis: Axis, in size: CGSize) -> CGFloat {
        let reference = axis == .x ? Self.legacyStageSize.width : Self.legacyStageSize.height
        let target = axis == .x ? size.width : size.height

        if abs(raw) <= 1 {
            return raw * target
        }
        return raw / reference * target
    }
}

private func alphaRange(from raw: Any?) -> (CGFloat, CGFloat) {
    if let text = stringValue(raw) {
        let parts = text.split(separator: "-").compactMap { Double($0) }
        if parts.count >= 2 {
            return (CGFloat(parts[0]), CGFloat(parts[1]))
        }
        if let single = parts.first {
            let alpha = CGFloat(single)
            return (alpha, alpha)
        }
    }

    if let scalar = scalarValue(raw) {
        let alpha = CGFloat(scalar)
        return (alpha, alpha)
    }

    return (1, 1)
}

private func scalarValue(_ raw: Any?) -> Double? {
    switch raw {
    case let number as NSNumber:
        return number.doubleValue
    case let text as String:
        return Double(text)
    default:
        return nil
    }
}

private func stringValue(_ raw: Any?) -> String? {
    switch raw {
    case let text as String:
        return text
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}