import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct CaptureOptions {
    public var name = "Prise"
    public var profile: QualityProfile = .balanced
    public var maxFPS: Int?                       // nil : celle du profil
    public var pixelFormat: PixelFormatChoice = .yuv420
    public var excludeOwnApp = true
    public var origin = "cli"
    public var client: String?
    public init() {}
}

/// Prise en cours : ScreenCaptureKit → encodeur matériel → fichier fragmenté, plus les événements à part.
/// Le chemin de capture ne fait aucun travail d'interface ; tout passe par des files dédiées.
public final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "mtapes.capture", qos: .userInteractive)
    private let stream: SCStream
    private let writer: VideoWriter
    private let events = EventRecorder()
    private let package: TapePackage
    private var meta: TapeMeta
    private var stats = TapeMeta.Stats()
    private var firstPTS: CMTime?
    private let requestedAt: Double
    private var streamError: Error?
    private var stopped = false
    fileprivate var holder: StreamHolder?

    fileprivate init(stream: SCStream, writer: VideoWriter, package: TapePackage, meta: TapeMeta, requestedAt: Double) {
        self.stream = stream; self.writer = writer; self.package = package; self.meta = meta; self.requestedAt = requestedAt
        super.init()
    }

    fileprivate func begin() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        events.start()
        do {
            try await stream.startCapture()
        } catch {
            _ = events.stop()
            if !Permissions.screenRecording { throw EngineError.screenRecordingDenied }
            throw error
        }
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete:
            break
        case .idle:
            stats.framesIdle += 1
            return
        case .blank:
            stats.framesBlank += 1
            return
        default:
            return
        }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        stats.framesComplete += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = pts
            stats.firstFrameLatency = max(0, CMTimeGetSeconds(pts) - requestedAt)
        }
        writer.append(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }

    // MARK: Arrêt

    /// Arrête la prise et écrit le paquet `.tape` ; renvoie ses métadonnées finales.
    public func stop() async throws -> (package: TapePackage, meta: TapeMeta) {
        guard !stopped else { throw EngineError.alreadyStopped }
        stopped = true
        let stopRequested = HostClock.now()
        let recorded = events.stop()
        try? await stream.stopCapture()
        queue.sync { }                                    // vide les dernières images en cours de traitement
        guard let firstPTS else {
            try? await writer.finish(endTime: .zero)
            throw streamError ?? EngineError.noFrames
        }
        let first = CMTimeGetSeconds(firstPTS)
        let end = CMTime(seconds: stopRequested, preferredTimescale: 600)
        try await writer.finish(endTime: end)

        stats.framesWritten = writer.written
        stats.framesDropped = writer.dropped
        stats.stopLatency = HostClock.now() - stopRequested
        let attrs = try? FileManager.default.attributesOfItem(atPath: package.rawURL.path)
        stats.bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // Événements et trajectoire rebasés sur la première image.
        let rebased = recorded.events.compactMap { e -> TapeEvent? in
            var e = e; e.t -= first
            return e.t >= -0.1 ? e : nil
        }
        try EventLog.encode(rebased).write(to: package.eventsURL, options: .atomic)
        let track = recorded.samples.map { (t: $0.t - first, x: $0.x, y: $0.y) }.filter { $0.t >= -0.1 }
        try PointerTrack.encode(track).write(to: package.pointerURL, options: .atomic)

        meta.durationSeconds = max(0, stopRequested - first)
        meta.firstFramePTS = first
        meta.stats = stats
        try package.writeMeta(meta)
        return (package, meta)
    }
}

public enum Recorder {
    /// Démarre une prise. Aucune fenêtre n'est ouverte, aucun focus n'est pris.
    public static func start(target: CaptureTarget, options: CaptureOptions, outputDirectory: URL) async throws -> RecordingSession {
        let content = try await TargetCatalog.content()
        let resolved = try TargetCatalog.resolve(target, content: content, excludeOwnApp: options.excludeOwnApp)
        let fps = options.maxFPS ?? options.profile.maxFPS

        let config = SCStreamConfiguration()
        config.width = resolved.pixelWidth
        config.height = resolved.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = options.pixelFormat.cvFormat
        config.showsCursor = false                   // le curseur est redessiné à la finition
        config.scalesToFit = false
        config.queueDepth = 6
        config.capturesAudio = false
        config.captureResolution = .best
        if let rect = resolved.sourceRect { config.sourceRect = rect }

        let package = try TapePackage.create(in: outputDirectory, name: options.name)
        let writer = try VideoWriter(url: package.rawURL, width: resolved.pixelWidth, height: resolved.pixelHeight,
                                     profile: options.profile, fps: fps, tenBit: options.pixelFormat.isTenBit)
        let meta = TapeMeta(
            id: UUID().uuidString.lowercased(), name: options.name, created: Date(), origin: options.origin,
            client: options.client, source: resolved.source, profile: options.profile.rawValue,
            pixelFormat: options.pixelFormat.rawValue, codec: options.pixelFormat.isTenBit ? "hevc-main10" : "hevc-main",
            maxFPS: fps, width: resolved.pixelWidth, height: resolved.pixelHeight,
            durationSeconds: 0, firstFramePTS: 0, stats: .init())

        let requestedAt = HostClock.now()
        let holder = StreamHolder()
        let stream = SCStream(filter: resolved.filter, configuration: config, delegate: holder)
        let session = RecordingSession(stream: stream, writer: writer, package: package, meta: meta, requestedAt: requestedAt)
        holder.session = session
        session.holder = holder
        try await session.begin()
        return session
    }
}

/// Relais du délégué : évite un cycle de références entre SCStream et la prise.
final class StreamHolder: NSObject, SCStreamDelegate {
    weak var session: RecordingSession?
    func stream(_ stream: SCStream, didStopWithError error: Error) { session?.stream(stream, didStopWithError: error) }
}
