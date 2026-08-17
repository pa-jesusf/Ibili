import Foundation
import XCTest
@testable import Ibili

final class PlaybackLoudnessNormalizerTests: XCTestCase {
    func testVolumeMetadataDecodesFromCoreJSONKeys() throws {
        let data = Data(
            """
            {
                "measured_i": -23.4,
                "measured_lra": 7.2,
                "measured_tp": -3.1,
                "measured_threshold": -34.0,
                "target_offset": 0.2,
                "target_i": -16.0,
                "target_tp": -1.5
            }
            """.utf8
        )

        let volume = try JSONDecoder().decode(PlayUrlVolumeDTO.self, from: data)

        XCTAssertEqual(volume.measuredI, -23.4)
        XCTAssertEqual(volume.measuredLra, 7.2)
        XCTAssertEqual(volume.measuredTp, -3.1)
        XCTAssertEqual(volume.targetI, -16)
        XCTAssertEqual(volume.targetTp, -1.5)
    }

    func testQuietVideoReclaimsBaseAttenuationWithoutBoostingAboveUnity() {
        let volume = PlayUrlVolumeDTO(
            measuredI: -30,
            measuredTp: -8,
            targetI: -16,
            targetTp: -1.5
        )

        let result = PlaybackLoudnessNormalizer.resolve(
            baseGainDb: -15,
            normalizationEnabled: true,
            volume: volume
        )

        XCTAssertEqual(result.correctionDb, 14, accuracy: 0.001)
        XCTAssertEqual(result.outputGainDb, -1, accuracy: 0.001)
        XCTAssertLessThan(result.linearVolume, 1)
    }

    func testLoudVideoReceivesAdditionalAttenuation() {
        let volume = PlayUrlVolumeDTO(
            measuredI: -8,
            measuredTp: -0.5,
            targetI: -16,
            targetTp: -1.5
        )

        let result = PlaybackLoudnessNormalizer.resolve(
            baseGainDb: -15,
            normalizationEnabled: true,
            volume: volume
        )

        XCTAssertEqual(result.correctionDb, -8, accuracy: 0.001)
        XCTAssertEqual(result.outputGainDb, -23, accuracy: 0.001)
    }

    func testTruePeakLimitsPositiveCorrection() {
        let volume = PlayUrlVolumeDTO(
            measuredI: -30,
            measuredTp: -0.5,
            targetI: -16,
            targetTp: -1.5
        )

        let result = PlaybackLoudnessNormalizer.resolve(
            baseGainDb: 0,
            normalizationEnabled: true,
            volume: volume
        )

        XCTAssertEqual(result.correctionDb, -1, accuracy: 0.001)
        XCTAssertEqual(result.outputGainDb, -1, accuracy: 0.001)
    }

    func testDisabledOrMissingAnalysisUsesBaseGain() {
        let volume = PlayUrlVolumeDTO(measuredI: -30, targetI: -16)

        XCTAssertEqual(
            PlaybackLoudnessNormalizer.resolve(
                baseGainDb: -15,
                normalizationEnabled: false,
                volume: volume
            ).outputGainDb,
            -15
        )
        XCTAssertEqual(
            PlaybackLoudnessNormalizer.resolve(
                baseGainDb: -15,
                normalizationEnabled: true,
                volume: nil
            ).outputGainDb,
            -15
        )
    }

    func testOutputNeverExceedsUnity() {
        let volume = PlayUrlVolumeDTO(measuredI: -50, targetI: -16)
        let result = PlaybackLoudnessNormalizer.resolve(
            baseGainDb: 0,
            normalizationEnabled: true,
            volume: volume
        )

        XCTAssertEqual(result.outputGainDb, 0)
        XCTAssertEqual(result.linearVolume, 1)
    }
}
