import AVFoundation
import Foundation

// Export : le calque de finition rendu en MP4 (H.264, débit réglé pour viser un poids) ou en GIF léger.

public enum Destination: String, CaseIterable {
    case readme, release, short

    public var preset: FinishingPreset { FinishingPreset(rawValue: rawValue)! }
    public var fileName: String {
        switch self {
        case .readme: return "readme.gif"
        case .release: return "release_1080p.mp4"
        case .short: return "short_9x16.mp4"
        }
    }
    public var isGIF: Bool { self == .readme }
    /// Poids visé par défaut (Mo).
    public var defaultTargetMegabytes: Double? { self == .readme ? 9.5 : nil }
}

public struct ExportResult: Codable {
    public var path: String
    public var format: String
    public var width: Int
    public var height: Int
    public var durationSeconds: Double
    public var megabytes: Double
    public var renderSeconds: Double           // temps de rendu proprement dit
    public var queuedSeconds: Double = 0      // attente derrière un autre calcul lourd (file `calcul-lourd`)
}

/// File d'attente commune des calculs lourds de ce Mac (même verrou que la commande `calcul-lourd`) : un seul rendu à la fois.
enum HeavyLock {
    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        let fd = open("/tmp/calcul-lourd.lock", O_CREAT | O_RDWR, 0o666)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try await body()
    }
}

public enum Exporter {
    public static func export(_ package: TapePackage, destination: Destination, spec: FinishingSpec? = nil, targetMegabytes: Double? = nil,
                              outputDirectory: URL? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportResult {
        let requested = Date()
        // Calque : celui qui est donné, sinon celui de la prise s'il vise la même destination (retouches à la main conservées), sinon un calque neuf.
        let finishing: FinishingSpec
        if let spec { finishing = spec }
        else if let saved = (try? Data(contentsOf: package.finishingURL)).flatMap({ try? JSONDecoder().decode(FinishingSpec.self, from: $0) }), saved.preset == destination.rawValue { finishing = saved }
        else { finishing = try Finisher.plan(package, preset: destination.preset) }
        let outDir = outputDirectory ?? package.exportsURL
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = targetMegabytes ?? destination.defaultTargetMegabytes

        return try await HeavyLock.run {
            let started = Date()
            let queued = started.timeIntervalSince(requested)
            if destination.isGIF {
                let mp4 = outDir.appendingPathComponent(".gif-source.mp4")
                defer { try? FileManager.default.removeItem(at: mp4) }
                let video = try await renderMP4(package, spec: finishing, to: mp4, targetMegabytes: 6, progress: { progress?($0 * 0.8) })
                let gif = outDir.appendingPathComponent(destination.fileName)
                try GIFEncoder.encode(mp4: mp4, to: gif, maxMegabytes: target ?? 9.5, sourceWidth: finishing.canvas.width)
                progress?(1)
                return result(gif, format: "gif", spec: finishing, duration: video.duration, started: started, queued: queued)
            }
            let url = outDir.appendingPathComponent(destination.fileName)
            let video = try await renderMP4(package, spec: finishing, to: url, targetMegabytes: target, progress: progress)
            return result(url, format: "mp4", spec: finishing, duration: video.duration, started: started, queued: queued)
        }
    }

    private static func result(_ url: URL, format: String, spec: FinishingSpec, duration: Double, started: Date, queued: Double) -> ExportResult {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        return ExportResult(path: url.path, format: format, width: spec.canvas.width, height: spec.canvas.height, durationSeconds: duration,
                            megabytes: (Double(bytes) / 10_000).rounded() / 100, renderSeconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, queuedSeconds: (queued * 10).rounded() / 10)
    }

    /// Rend le film : compositeur, lecteur, écrivain H.264 au débit calculé pour viser `targetMegabytes` (sinon un débit adapté au format).
    static func renderMP4(_ package: TapePackage, spec: FinishingSpec, to url: URL, targetMegabytes: Double?, progress: (@Sendable (Double) -> Void)?) async throws -> (duration: Double, bytes: Int64) {
        let built = try await Finisher.build(package, spec: spec)
        try? FileManager.default.removeItem(at: url)

        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                         videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.writerFailed("lecture du film impossible") }
        reader.add(output)

        let pixels = Double(spec.canvas.width * spec.canvas.height)
        var bitrate = pixels * Double(spec.fps) * 0.045                          // débit par défaut, plafonné ensuite
        bitrate = min(12_000_000, max(800_000, bitrate))
        if let mb = targetMegabytes, built.duration > 0 { bitrate = max(300_000, mb * 8_000_000 * 0.92 / built.duration) }

        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: spec.canvas.width, AVVideoHeightKey: spec.canvas.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(bitrate), AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoMaxKeyFrameIntervalKey: spec.fps * 2, AVVideoExpectedSourceFrameRateKey: spec.fps],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError.writerFailed("réglages d'export refusés") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw EngineError.writerFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "démarrage impossible") }
        writer.startSession(atSourceTime: .zero)

        let box = ExportBox(reader: reader, output: output, writer: writer, input: input, duration: built.duration, progress: progress)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "mtapes.export")
            input.requestMediaDataWhenReady(on: queue) {
                while box.input.isReadyForMoreMediaData {
                    let tA = CFAbsoluteTimeGetCurrent()
                    if let sample = box.output.copyNextSampleBuffer() {
                        let tB = CFAbsoluteTimeGetCurrent()
                        box.input.append(sample)
                        if ProcessInfo.processInfo.environment["MTAPES_PROFILE"] != nil { box.addTimes(read: tB - tA, write: CFAbsoluteTimeGetCurrent() - tB) }
                        box.progress?(min(0.99, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / max(0.1, box.duration)))
                    } else {
                        box.input.markAsFinished()
                        box.writer.finishWriting {
                            if box.writer.status == .completed { cont.resume() }
                            else { cont.resume(throwing: EngineError.writerFailed(box.writer.error?.localizedDescription ?? "écriture du film")) }
                        }
                        return
                    }
                    if box.reader.status == .failed {
                        box.input.markAsFinished()
                        box.writer.cancelWriting()
                        cont.resume(throwing: EngineError.writerFailed(box.reader.error?.localizedDescription ?? "lecture du film"))
                        return
                    }
                }
            }
        }
        progress?(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        return (built.duration, bytes)
    }
}

private final class ExportBox: @unchecked Sendable {
    let reader: AVAssetReader, output: AVAssetReaderVideoCompositionOutput, writer: AVAssetWriter, input: AVAssetWriterInput
    let duration: Double
    let progress: (@Sendable (Double) -> Void)?
    private var read = 0.0, write = 0.0, n = 0
    func addTimes(read r: Double, write w: Double) {
        read += r; write += w; n += 1
        if n % 100 == 0 { FileHandle.standardError.write(Data(String(format: "[export] %d images : lecture+composition %.1f ms, écriture %.1f ms par image\n", n, read / Double(n) * 1000, write / Double(n) * 1000).utf8)) }
    }
    init(reader: AVAssetReader, output: AVAssetReaderVideoCompositionOutput, writer: AVAssetWriter, input: AVAssetWriterInput, duration: Double, progress: (@Sendable (Double) -> Void)?) {
        self.reader = reader; self.output = output; self.writer = writer; self.input = input; self.duration = duration; self.progress = progress
    }
}

/// GIF léger : palette adaptative par `ffmpeg` quand il est présent (poids visé tenu en réduisant cadence puis largeur) ;
/// repli ImageIO (palette fixe, plus lourd) sinon.
enum GIFEncoder {
    static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func encode(mp4: URL, to gif: URL, maxMegabytes: Double, sourceWidth: Int) throws {
        guard let ffmpeg = ffmpegPath() else { try imageIOFallback(mp4: mp4, to: gif, width: min(sourceWidth, 800), fps: 10); return }
        let attempts: [(Int, Int)] = [(min(sourceWidth, 960), 15), (min(sourceWidth, 960), 12), (min(sourceWidth, 800), 12), (min(sourceWidth, 720), 10), (min(sourceWidth, 640), 10), (min(sourceWidth, 480), 8)]
        for (width, fps) in attempts {
            try? FileManager.default.removeItem(at: gif)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", mp4.path, "-vf",
                           "fps=\(fps),scale=\(width):-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
                           "-loop", "0", gif.path]
            p.standardError = Pipe(); p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw EngineError.writerFailed("ffmpeg a échoué pour le GIF") }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? NSNumber)??.doubleValue ?? 0
            if bytes / 1_000_000 <= maxMegabytes { return }
        }
    }

    static func imageIOFallback(mp4: URL, to gif: URL, width: Int, fps: Int) throws {
        let asset = AVURLAsset(url: mp4)
        let seconds = CMTimeGetSeconds(asset.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: width, height: width)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let count = max(1, Int(seconds * Double(fps)))
        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, count, nil) else { throw EngineError.writerFailed("GIF impossible") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for i in 0..<count {
            let image = try generator.copyCGImage(at: CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600), actualTime: nil)
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1.0 / Double(fps)]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw EngineError.writerFailed("GIF non finalisé") }
    }
}
