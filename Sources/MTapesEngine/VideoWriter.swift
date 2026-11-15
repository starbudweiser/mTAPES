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

    /// Référence quasi sans perte (ProRes 4444), pour mesurer la qualité du brut : mêmes images, mêmes horodatages.
    init(referenceURL url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(url: url, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw EngineError.writerFailed("référence refusée") }
        writer.add(input)
        guard writer.startWriting() else {
            throw EngineError.writerFailed(writer.error?.localizedDescription ?? "démarrage impossible")
        }
    }

    init(url: URL, width: Int, height: Int, profile: QualityProfile, fps: Int, tenBit: Bool, quality: Double? = nil, keyFrameInterval: Double? = nil) throws {
        writer = try AVAssetWriter(url: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let level = tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        let compression: [String: Any] = [
            AVVideoQualityKey: quality ?? profile.videoQuality,
            AVVideoMaxKeyFrameIntervalDurationKey: keyFrameInterval ?? profile.keyFrameInterval,
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

    /// Version hors temps réel (banc d'essai de l'encodeur) : attend que l'encodeur soit prêt au lieu de perdre l'image.
    func appendWaiting(_ sampleBuffer: CMSampleBuffer, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { usleep(500) }
        return append(sampleBuffer)
    }

    /// Abandonne l'écriture (départ raté, prise sans image).
    func cancel() { if writer.status == .writing { writer.cancelWriting() } }

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
