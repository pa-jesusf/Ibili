import Foundation

struct PlaybackLoudnessResolution: Equatable {
    let correctionDb: Double
    let outputGainDb: Double
    let linearVolume: Float
}

enum PlaybackLoudnessNormalizer {
    static let defaultTargetIntegratedLoudnessDb = -16.0
    static let defaultTargetTruePeakDb = -1.5

    static func resolve(
        baseGainDb: Double,
        normalizationEnabled: Bool,
        volume: PlayUrlVolumeDTO?
    ) -> PlaybackLoudnessResolution {
        let base = clamp(baseGainDb, to: -20...0)
        let requestedCorrection = normalizationEnabled ? correctionDb(for: volume) ?? 0 : 0
        var output = base + requestedCorrection
        if normalizationEnabled, let peakCeiling = truePeakGainCeilingDb(for: volume) {
            output = min(output, peakCeiling)
        }
        output = clamp(output, to: -44...0)
        return PlaybackLoudnessResolution(
            correctionDb: output - base,
            outputGainDb: output,
            linearVolume: Float(pow(10, output / 20))
        )
    }

    static func correctionDb(for volume: PlayUrlVolumeDTO?) -> Double? {
        guard let volume,
              let measuredI = volume.measuredI,
              measuredI.isFinite,
              measuredI < 0,
              measuredI >= -70 else {
            return nil
        }

        let targetI = validNegative(volume.targetI, range: -70..<0)
            ?? defaultTargetIntegratedLoudnessDb
        return clamp(targetI - measuredI, to: -24...15)
    }

    private static func truePeakGainCeilingDb(for volume: PlayUrlVolumeDTO?) -> Double? {
        guard let measuredTp = volume?.measuredTp,
              measuredTp.isFinite,
              (-100...20).contains(measuredTp) else {
            return nil
        }
        let targetTp: Double
        if let candidate = volume?.targetTp,
           candidate.isFinite,
           (-9...0).contains(candidate) {
            targetTp = candidate
        } else {
            targetTp = defaultTargetTruePeakDb
        }
        return targetTp - measuredTp
    }

    private static func validNegative(_ value: Double?, range: Range<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
