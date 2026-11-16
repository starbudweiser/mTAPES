import AVFoundation
import CoreMedia
import Foundation

/// Écrit une piste son (son du Mac ou micro) dans un fichier à part du paquet `.tape` : AAC, fichier fragmenté (lisible après un plantage).
/// Le brut vidéo n'est jamais touché ; le décalage de la première trame sonore par rapport à la première image est conservé dans `meta.json`.
final class AudioWriter {
    let kind: String                      // "system" | "mic"
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var firstPTS: CMTime?
    private(set) var lastEnd = CMTime.invalid
    private(set) var failed = false

    init(kind: String, url: URL) { self.kind = kind; self.url = url }

    /// Crée l'écriture à la première trame, d'après son format réel (cadence et nombre de canaux varient selon le micro).
    func append(_ sb: CMSampleBuffer) {
        guard !failed, sb.isValid, CMSampleBufferDataIsReady(sb), CMSampleBufferGetNumSamples(sb) > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if writer == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
            let channels = Int(min(2, max(1, asbd.mChannelsPerFrame)))
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000,
                                           AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 64_000 * channels]
            do {
                let w = try AVAssetWriter(url: url, fileType: .mov)
                w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                w.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                i.expectsMediaDataInRealTime = true
                guard w.canAdd(i) else { failed = true; return }
                w.add(i)
                guard w.startWriting() else { failed = true; return }
                w.startSession(atSourceTime: pts)
                writer = w; input = i; firstPTS = pts
            } catch { failed = true; return }
        }
        guard let input, let writer, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sb) {
            let d = CMSampleBufferGetDuration(sb)
            lastEnd = CMTimeAdd(pts, d.isValid ? d : .zero)
        }
    }

    /// Termine le fichier ; renvoie la piste si elle contient du son.
    func finish() async -> TapeMeta.AudioTrack? {
        guard let writer, let input, let firstPTS else { return nil }
        input.markAsFinished()
        if lastEnd.isValid { writer.endSession(atSourceTime: lastEnd) }
        await writer.finishWriting()
        guard writer.status == .completed else { try? FileManager.default.removeItem(at: url); return nil }
        let end = lastEnd.isValid ? CMTimeGetSeconds(lastEnd) : CMTimeGetSeconds(firstPTS)
        return .init(kind: kind, file: url.lastPathComponent, start: CMTimeGetSeconds(firstPTS), duration: max(0, end - CMTimeGetSeconds(firstPTS)))
    }

    func cancel() {
        if let writer, writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Autorisation du micro (ScreenCaptureKit en réclame une pour enregistrer la voix).
extension Permissions {
    public static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    /// Demande l'autorisation si elle n'a pas encore été posée ; false si elle est refusée.
    public static func ensureMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
