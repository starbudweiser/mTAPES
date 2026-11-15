import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Écrit le brut : HEVC matériel, qualité constante, image clé chaque seconde, fichier fragmenté (fragment de 2 s) :
/// un plantage ou une coupure de courant laisse un fichier lisible.
final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false
    private(set) var lastPTS = CMTime.invalid
    private(set) var written = 0
    private(set) var dropped = 0

    init(url: URL, width: Int, height: Int, profile: QualityProfile, fps: Int, tenBit: Bool) throws {
        writer = try AVAssetWriter(url: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let level = tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        let compression: [String: Any] = [
            AVVideoQualityKey: profile.videoQuality,
            AVVideoMaxKeyFrameIntervalDurationKey: profile.keyFrameInterval,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoProfileLevelKey: level as String,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw EngineError.writerFailed("réglages d'encodeur refusés") }
        writer.add(input)
        guard writer.startWriting() else {
            throw EngineError.writerFailed(writer.error?.localizedDescription ?? "démarrage impossible")
        }
    }

    /// Ajoute une image ; false si l'encodeur n'était pas prêt (image perdue, comptée).
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else {
            dropped += 1
            return false
        }
        if input.append(sampleBuffer) {
            written += 1
            lastPTS = pts
            return true
        }
        dropped += 1
        return false
    }

    var failure: String? { writer.status == .failed ? (writer.error?.localizedDescription ?? "échec") : nil }

    /// Termine le fichier ; `endTime` fixe la durée réelle (la dernière image est tenue jusque-là).
    func finish(endTime: CMTime) async throws {
        guard sessionStarted else {
            writer.cancelWriting()
            throw EngineError.noFrames
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(endTime, lastPTS))
        await writer.finishWriting()
        if writer.status != .completed {
            throw EngineError.writerFailed(writer.error?.localizedDescription ?? "fin de fichier impossible")
        }
    }
}
