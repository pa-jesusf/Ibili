import CoreGraphics
import Foundation

/// Parser for Bilibili mode-7 special danmaku payloads.
///
/// This mirrors the upstream `canvas_danmaku` behavior for the fields it
/// actually implements today: normalized positioning, alpha tween, delayed
/// translation, optional stroke, and rotateZ/rotateY transforms. Upstream
/// still leaves motion paths unimplemented, so this parser intentionally keeps
/// that boundary as well.
struct SpecialDanmakuDescriptor {
    let text: String
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let startAlpha: CGFloat
    let endAlpha: CGFloat
    let animatesAlpha: Bool
    let delay: Double
    let moveDuration: Double
    let displayDuration: Double
    let hasStroke: Bool
    let easing: Easing
    let transform: CGAffineTransform

    private static let referenceStageSize = CGSize(width: 1920, height: 1080)

    enum Easing {
        case linear
        case easeInCubic

        func value(at progress: CGFloat) -> CGFloat {
            let clamped = min(max(progress, 0), 1)
            switch self {
            case .linear:
                return clamped
            case .easeInCubic:
                return clamped * clamped * clamped
            }
        }
    }

    static func parse(rawText: String) -> SpecialDanmakuDescriptor? {
        let sanitized = rawText.replacingOccurrences(of: "\n", with: "\\n")
        guard let data = sanitized.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any],
              payload.count >= 5 else { return nil }

        let parsedText = stringValue(payload[safe: 4])?
            .replacingOccurrences(of: "/n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = parsedText, !text.isEmpty else { return nil }

        let (startX, endX) = relativePosition(
            from: payload[safe: 0],
            to: payload[safe: 7],
            videoSize: referenceStageSize.width
        )
        let (startY, endY) = relativePosition(
            from: payload[safe: 1],
            to: payload[safe: 8],
            videoSize: referenceStageSize.height
        )
        let (startAlpha, endAlpha) = alphaRange(from: payload[safe: 2])
        let baseDuration = max(scalarValue(payload[safe: 3]) ?? 4.0, 0.1)
        let rawMoveDuration = scalarValue(payload[safe: 9]) ?? (baseDuration * 1000.0)
        let moveDuration = rawMoveDuration > 0 ? rawMoveDuration / 1000.0 : 0.001
        let delay = max((scalarValue(payload[safe: 10]) ?? 0) / 1000.0, 0)
        let hasStroke = intValue(payload[safe: 11]) == 1
        let easing: Easing = intValue(payload[safe: 13]) == 1 ? .easeInCubic : .linear
        let rotateZ = degreesToRadians(intValue(payload[safe: 5]))
        let rotateY = degreesToRadians(intValue(payload[safe: 6]))

        let alphaAnimates = abs(startAlpha - endAlpha) > 0.0001
        let resolvedStartAlpha = alphaAnimates ? startAlpha : (startAlpha + endAlpha) * 0.5
        let resolvedEndAlpha = alphaAnimates ? endAlpha : resolvedStartAlpha

        return SpecialDanmakuDescriptor(
            text: text,
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            startAlpha: resolvedStartAlpha,
            endAlpha: resolvedEndAlpha,
            animatesAlpha: alphaAnimates,
            delay: delay,
            moveDuration: moveDuration,
            displayDuration: baseDuration,
            hasStroke: hasStroke,
            easing: easing,
            transform: makeTransform(rotateZ: rotateZ, rotateY: rotateY)
        )
    }

    func position(at elapsed: Double, in size: CGSize) -> CGPoint {
        let progress = moveProgress(at: elapsed)
        let start = CGPoint(
            x: startX * size.width,
            y: startY * size.height
        )
        let end = CGPoint(
            x: endX * size.width,
            y: endY * size.height
        )
        return CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    func alpha(at elapsed: Double) -> CGFloat {
        guard animatesAlpha else { return startAlpha }
        let progress = CGFloat(min(max(elapsed / max(displayDuration, 0.001), 0), 1))
        return clampAlpha(startAlpha + (endAlpha - startAlpha) * progress)
    }

    private func moveProgress(at elapsed: Double) -> CGFloat {
        guard elapsed > delay else { return 0 }
        let motionElapsed = min(max(elapsed - delay, 0), moveDuration)
        let linearProgress = CGFloat(motionElapsed / moveDuration)
        return easing.value(at: linearProgress)
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

private func relativePosition(from rawStart: Any?, to rawEnd: Any?, videoSize: CGFloat) -> (CGFloat, CGFloat) {
    var start = scalarValue(rawStart)
    var end = scalarValue(rawEnd)

    guard start != nil || end != nil else { return (0, 0) }

    if start == nil { start = end }
    if end == nil { end = start }

    return (
        normalizeCoordinate(start ?? 0, raw: rawStart, videoSize: videoSize),
        normalizeCoordinate(end ?? 0, raw: rawEnd, videoSize: videoSize)
    )
}

private func normalizeCoordinate(_ value: Double, raw: Any?, videoSize: CGFloat) -> CGFloat {
    if value > 1 || (raw as? String).map({ !$0.contains(".") }) == true {
        return CGFloat(value / Double(videoSize))
    }
    return CGFloat(value)
}

private func degreesToRadians(_ degrees: Int) -> CGFloat {
    CGFloat(degrees) * .pi / 180
}

private func makeTransform(rotateZ: CGFloat, rotateY: CGFloat) -> CGAffineTransform {
    var transform = CGAffineTransform.identity
    if rotateZ != 0 {
        transform = transform.rotated(by: rotateZ)
    }
    if rotateY != 0 {
        transform = transform.scaledBy(x: cos(rotateY), y: 1)
    }
    return transform
}

private func clampAlpha(_ value: CGFloat) -> CGFloat {
    min(max(value, 0), 1)
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

private func intValue(_ raw: Any?) -> Int {
    switch raw {
    case let number as NSNumber:
        return number.intValue
    case let text as String:
        return Int(text) ?? 0
    default:
        return 0
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