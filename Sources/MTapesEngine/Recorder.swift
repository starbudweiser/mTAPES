import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct CaptureOptions {
    public var name = "Prise"
    public var profile: QualityProfile = .balanced
    public var maxFPS: Int?                       // nil : celle du profil
    public var pixelFormat: PixelFormatChoice = .yuv420
    public var keyFrameInterval: Double?          // nil : celui du profil
    public var excludeOwnApp = true
    public var origin = "cli"
    public var client: String?
    public var referenceURL: URL?                 // banc d'essai : copie quasi sans perte des mêmes images
    public init() {}
}

/// Prise en cours : ScreenCaptureKit → encodeur matériel → fichier fragmenté, plus les événements à part.
/// Le chemin de capture ne fait aucun travail d'interface ; tout passe par des files dédiées.
/// Pendant la prise, `meta.json`, `events.jsonl` et `pointer.bin` sont réécrits toutes les 5 s : un plantage ne perd que les dernières secondes.
public final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Problème détecté pendant la prise ; signalé une fois (`noFrames` de nouveau si les images reviennent puis disparaissent).
    public enum Problem: String {
        case streamStopped      // le système (ou l'utilisateur, via l'indicateur de partage) a coupé le flux
        case noFrames           // plus aucune notification d'image depuis plusieurs secondes
        case writerFailed       // l'écriture du fichier vidéo a échoué
    }

    /// Appelé depuis une file interne : ne rien faire de lourd, rebondir vers le fil principal.
    public var onProblem: (@Sendable (Problem) -> Void)?

    private let queue = DispatchQueue(label: "mtapes.capture", qos: .userInteractive)
    private let stream: SCStream
    private let writer: VideoWriter
    private let reference: VideoWriter?
    private let events = EventRecorder()
    private let package: TapePackage
    private var meta: TapeMeta
    private var stats = TapeMeta.Stats()
    private var firstPTS: CMTime?
    private var lastCallback: Double
    private let requestedAt: Double
    private var streamError: Error?
    private var streamStoppedAt: Double?
    private var stopped = false
    private var reported = Set<String>()
    private var declared: [TapeEvent] = []          // actions annoncées par l'IA (source « declared »)
    private var watchdog: DispatchSourceTimer?
    private var persister: DispatchSourceTimer?
    fileprivate var holder: StreamHolder?

    fileprivate init(stream: SCStream, writer: VideoWriter, reference: VideoWriter?, package: TapePackage, meta: TapeMeta, requestedAt: Double) {
        self.stream = stream; self.writer = writer; self.reference = reference; self.package = package; self.meta = meta
        self.requestedAt = requestedAt; self.lastCallback = requestedAt
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
        startTimers()
    }

    private func startTimers() {
        let dog = DispatchSource.makeTimerSource(queue: queue)
        dog.schedule(deadline: .now() + 2, repeating: 2)
        dog.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if HostClock.now() - self.lastCallback > 6 { self.report(.noFrames) }
        }
        dog.resume()
        watchdog = dog

        let save = DispatchSource.makeTimerSource(queue: queue)
        save.schedule(deadline: .now() + 5, repeating: 5)
        save.setEventHandler { [weak self] in self?.persistSnapshot() }
        save.resume()
        persister = save
    }

    private func report(_ problem: Problem) {
        if reported.insert(problem.rawValue).inserted { onProblem?(problem) }
    }

    /// Réécrit événements, trajectoire et métadonnées provisoires (état « recording ») : ce qui survit à un plantage.
    private func persistSnapshot() {
        guard let firstPTS, !stopped else { return }
        let first = CMTimeGetSeconds(firstPTS)
        let snap = events.snapshot()
        let rebased = (snap.events + declared).sorted { $0.t < $1.t }.compactMap { e -> TapeEvent? in var e = e; e.t -= first; return e.t >= -0.1 ? e : nil }
        try? EventLog.encode(rebased).write(to: package.eventsURL, options: .atomic)
        let track = snap.samples.map { (t: $0.t - first, x: $0.x, y: $0.y) }.filter { $0.t >= -0.1 }
        try? PointerTrack.encode(track).write(to: package.pointerURL, options: .atomic)
        var m = meta
        m.state = "recording"
        m.firstFramePTS = first
        m.durationSeconds = max(0, HostClock.now() - first)
        m.stats = stats
        m.stats.framesWritten = writer.written
        m.stats.framesDropped = writer.dropped
        try? package.writeMeta(m)
    }

    // MARK: Actions annoncées, état

    /// Enregistre une action annoncée (clic, saisie, chapitre…) à l'instant présent ; renvoie son temps dans la vidéo si la première image est arrivée.
    @discardableResult
    public func mark(kind: String, x: Double?, y: Double?, label: String?, button: String? = nil) -> Double? {
        queue.sync {
            let t = HostClock.now()
            declared.append(TapeEvent(t: t, kind: kind, x: x, y: y, button: button, source: "declared", label: label))
            return firstPTS.map { t - CMTimeGetSeconds($0) }
        }
    }

    /// Compteurs en direct (images écrites, refusées…).
    public var liveStats: TapeMeta.Stats {
        queue.sync {
            var s = stats
            s.framesWritten = writer.written
            s.framesDropped = writer.dropped
            return s
        }
    }

    public var packageURL: URL { package.url }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        lastCallback = HostClock.now()
        reported.remove(Problem.noFrames.rawValue)
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
        reference?.append(sampleBuffer)
        if writer.failure != nil { report(.writerFailed) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            self.streamError = error
            self.streamStoppedAt = HostClock.now()
            self.report(.streamStopped)
        }
    }

    // MARK: Arrêt

    /// Arrête la prise et écrit le paquet `.tape` ; renvoie ses métadonnées finales.
    /// Même si l'écriture vidéo échoue, événements et métadonnées sont écrits (avec l'erreur) avant que l'erreur soit renvoyée.
    public func stop() async throws -> (package: TapePackage, meta: TapeMeta) {
        guard !stopped else { throw EngineError.alreadyStopped }
        queue.sync { stopped = true; watchdog?.cancel(); persister?.cancel() }
        let stopRequested = HostClock.now()
        let recorded = events.stop()
        try? await stream.stopCapture()
        queue.sync { }                                    // vide les dernières images en cours de traitement
        guard let firstPTS else {
            writer.cancel(); reference?.cancel()
            try? FileManager.default.removeItem(at: package.url)
            throw streamError ?? EngineError.noFrames
        }
        let first = CMTimeGetSeconds(firstPTS)
        let endHost = streamStoppedAt ?? stopRequested   // un flux coupé par le système : la durée s'arrête à la coupure
        let end = CMTime(seconds: endHost, preferredTimescale: 600)
        var finishError: Error?
        do { try await writer.finish(endTime: end) } catch { finishError = error }
        try? await reference?.finish(endTime: end)

        stats.framesWritten = writer.written
        stats.framesDropped = writer.dropped
        stats.stopLatency = HostClock.now() - stopRequested
        let attrs = try? FileManager.default.attributesOfItem(atPath: package.rawURL.path)
        stats.bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let rebased = (recorded.events + declared).sorted { $0.t < $1.t }.compactMap { e -> TapeEvent? in
            var e = e; e.t -= first
            return e.t >= -0.1 ? e : nil
        }
        try EventLog.encode(rebased).write(to: package.eventsURL, options: .atomic)
        let track = recorded.samples.map { (t: $0.t - first, x: $0.x, y: $0.y) }.filter { $0.t >= -0.1 }
        try PointerTrack.encode(track).write(to: package.pointerURL, options: .atomic)

        meta.durationSeconds = max(0, endHost - first)
        meta.firstFramePTS = first
        meta.stats = stats
        meta.state = finishError == nil ? "complete" : "failed"
        meta.error = finishError.map { "\($0)" } ?? streamError.map { "Flux interrompu : \($0.localizedDescription)" }
        try package.writeMeta(meta)
        if let finishError { throw finishError }
        return (package, meta)
    }
}

public enum Recorder {
    /// Démarre une prise. Aucune fenêtre n'est ouverte, aucun focus n'est pris.
    /// En cas d'échec, rien ne reste sur le disque (le dossier `.tape` créé est supprimé).
    public static func start(target: CaptureTarget, options: CaptureOptions, outputDirectory: URL) async throws -> RecordingSession {
        try ensureDiskSpace(outputDirectory)
        let content = try await TargetCatalog.content()
        let resolved = try TargetCatalog.resolve(target, content: content, excludeOwnApp: options.excludeOwnApp)
        let fps = options.maxFPS ?? options.profile.maxFPS

        let config = SCStreamConfiguration()
        config.width = resolved.pixelWidth
        config.height = resolved.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = options.pixelFormat.cvFormat
        config.colorSpaceName = CGColorSpace.sRGB     // couleurs justes sur un écran P3 (cible : README, web)
        config.showsCursor = false                   // le curseur est redessiné à la finition
        config.scalesToFit = false
        config.queueDepth = 6
        config.capturesAudio = false
        config.captureResolution = .best
        if let rect = resolved.sourceRect { config.sourceRect = rect }

        let package = try TapePackage.create(in: outputDirectory, name: options.name)
        var writer: VideoWriter?
        var reference: VideoWriter?
        do {
            let w = try VideoWriter(url: package.rawURL, width: resolved.pixelWidth, height: resolved.pixelHeight,
                                    profile: options.profile, fps: fps, tenBit: options.pixelFormat.isTenBit,
                                    keyFrameInterval: options.keyFrameInterval)
            writer = w
            reference = try options.referenceURL.map { try VideoWriter(referenceURL: $0, width: resolved.pixelWidth, height: resolved.pixelHeight) }
            var meta = TapeMeta(
                id: UUID().uuidString.lowercased(), name: options.name, created: Date(), origin: options.origin,
                client: options.client, source: resolved.source, profile: options.profile.rawValue,
                pixelFormat: options.pixelFormat.rawValue, codec: options.pixelFormat.isTenBit ? "hevc-main10" : "hevc-main",
                maxFPS: fps, width: resolved.pixelWidth, height: resolved.pixelHeight,
                durationSeconds: 0, firstFramePTS: 0, stats: .init())
            meta.state = "recording"
            try package.writeMeta(meta)

            let requestedAt = HostClock.now()
            let holder = StreamHolder()
            let stream = SCStream(filter: resolved.filter, configuration: config, delegate: holder)
            let session = RecordingSession(stream: stream, writer: w, reference: reference, package: package, meta: meta, requestedAt: requestedAt)
            holder.session = session
            session.holder = holder
            try await session.begin()
            return session
        } catch {
            writer?.cancel(); reference?.cancel()
            try? FileManager.default.removeItem(at: package.url)
            throw error
        }
    }

    /// Refuse de démarrer s'il reste moins de 2 Go sur le volume de sortie.
    static func ensureDiskSpace(_ directory: URL, minimum: Int64 = 2_000_000_000) throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < minimum { throw EngineError.diskLow }
    }
}

/// Relais du délégué : évite un cycle de références entre SCStream et la prise.
final class StreamHolder: NSObject, SCStreamDelegate {
    weak var session: RecordingSession?
    func stream(_ stream: SCStream, didStopWithError error: Error) { session?.stream(stream, didStopWithError: error) }
}
