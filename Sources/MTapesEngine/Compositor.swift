import AVFoundation
import AppKit
import CoreImage
import CoreText
import Foundation

// Rendu de la finition : AVFoundation (compositeur personnalisé) + Core Image (GPU). Le brut est lu tel quel ;
// fond, cadre arrondi, ombre, zoom adouci, curseur redessiné, ondes de clic et légendes sont composés image par image.

/// Tout ce que le rendu de chaque image a besoin de savoir, préparé une fois.
final class FinishingContext: @unchecked Sendable {
    let spec: FinishingSpec
    let outputP3: Bool                       // film rendu et étiqueté en Display P3
    let source: CGSize                       // pixels de la prise
    let canvas: CGSize
    let timeline: FinishingSpec.Timeline
    let screenRect: CGRect                   // zone de la prise dans le canevas (repère Core Image : origine en bas à gauche)
    let pointer: [(t: Double, nx: Double, ny: Double)]
    let clicks: [(t: Double, nx: Double, ny: Double)]
    let backdrop: CIImage                    // fond + ombre, calculé une fois
    let mask: CIImage                        // rectangle arrondi blanc de la taille de screenRect, à sa place
    let cursorSprite: CIImage
    let cursorHeight: CGFloat
    let ringSprite: CIImage
    private var captionCache: [String: CIImage] = [:]
    private let lock = NSLock()

    init(spec: FinishingSpec, meta: TapeMeta, sourceSize: CGSize, sourceDuration: Double, events: [TapeEvent], pointerSamples: [(t: Double, x: Double, y: Double)]) {
        self.spec = spec
        self.outputP3 = (spec.colors ?? meta.colorSpace ?? "srgb") == "p3"
        self.source = sourceSize
        self.canvas = CGSize(width: spec.canvas.width, height: spec.canvas.height)
        self.timeline = spec.timeline(sourceDuration: sourceDuration)

        let cw = CGFloat(spec.canvas.width), ch = CGFloat(spec.canvas.height)
        let margin = cw * CGFloat(spec.canvas.marginPercent) / 100
        let avail = CGRect(x: margin, y: margin, width: cw - 2 * margin, height: ch - 2 * margin)
        if spec.canvas.fill {
            screenRect = avail
        } else {
            let scale = min(avail.width / sourceSize.width, avail.height / sourceSize.height)
            let w = sourceSize.width * scale, h = sourceSize.height * scale
            screenRect = CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
        }

        // Positions normalisées dans l'image de la prise (origine en haut à gauche).
        let b = meta.source.bounds.count == 4 ? meta.source.bounds : [0, 0, Double(sourceSize.width), Double(sourceSize.height)]
        _ = b
        let geometry = GeometryTrack(meta: meta, events: events)
        func norm(_ x: Double, _ y: Double, _ t: Double) -> (Double, Double) { geometry.normalize(x: x, y: y, at: t) }
        var smoothed: [(t: Double, nx: Double, ny: Double)] = []
        var lx = 0.0, ly = 0.0, lt = 0.0
        for (i, s) in pointerSamples.enumerated() {
            let (nx, ny) = norm(s.x, s.y, s.t)
            if i == 0 || spec.cursor.smoothing <= 0 { lx = nx; ly = ny } else {
                let a = 1 - exp(-max(0, s.t - lt) / spec.cursor.smoothing)        // lissage tenant compte du temps écoulé
                lx += (nx - lx) * a; ly += (ny - ly) * a
            }
            lt = s.t
            smoothed.append((s.t, lx, ly))
        }
        pointer = smoothed
        clicks = events.compactMap { e in
            guard ["click", "doubleclick", "rightclick"].contains(e.kind), let x = e.x, let y = e.y else { return nil }
            let (nx, ny) = norm(x, y, e.t)
            return (e.t, nx, ny)
        }

        // Fond : dégradé vertical ; ombre douce sous la prise.
        let top = CIColor(red: CGFloat(spec.canvas.backgroundTop[0]), green: CGFloat(spec.canvas.backgroundTop[1]), blue: CGFloat(spec.canvas.backgroundTop[2]))
        let bottom = CIColor(red: CGFloat(spec.canvas.backgroundBottom[0]), green: CGFloat(spec.canvas.backgroundBottom[1]), blue: CGFloat(spec.canvas.backgroundBottom[2]))
        let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: ch), "inputColor0": top,
                                                                        "inputPoint1": CIVector(x: cw, y: 0), "inputColor1": bottom])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: cw, height: ch))
        let radius = CGFloat(spec.canvas.cornerRadius)
        mask = FinishingContext.roundedMask(rect: screenRect, canvas: CGSize(width: cw, height: ch), radius: radius, color: .white)
        if spec.canvas.shadow {
            let dark = FinishingContext.roundedMask(rect: screenRect.offsetBy(dx: 0, dy: -ch * 0.018), canvas: CGSize(width: cw, height: ch), radius: radius, color: .black)
            let blurred = dark.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: ch * 0.03]).cropped(to: CGRect(x: 0, y: 0, width: cw, height: ch))
            let faded = blurred.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
            backdrop = faded.composited(over: gradient)
        } else {
            backdrop = gradient
        }

        let scaleUI = cw / 1920
        cursorHeight = 30 * scaleUI * CGFloat(spec.cursor.sizePercent) / 100
        cursorSprite = FinishingContext.cursorImage(height: cursorHeight)
        ringSprite = FinishingContext.ringImage()
    }

    // MARK: Rendu d'une image

    func render(sourceBuffer: CVPixelBuffer, outputTime c: Double) -> CIImage {
        let s = timeline.sourceTime(forOutput: c)
        let srcW = source.width, srcH = source.height
        let cur = cursorPosition(at: s)

        // Région visible de la prise (zoom).
        var (z, fx, fy) = spec.zoomState(at: s)
        if spec.canvas.fill, z < 1.02, let cur { fx = cur.0; fy = cur.1 }          // vertical : le cadre suit le curseur hors zoom
        let aspect = screenRect.width / screenRect.height
        var rh = srcH / CGFloat(z), rw = rh * aspect
        if rw > srcW { rw = srcW; rh = rw / aspect }
        let cx = min(max(CGFloat(fx) * srcW, rw / 2), srcW - rw / 2)
        let cy = min(max(CGFloat(fy) * srcH, rh / 2), srcH - rh / 2)
        let region = CGRect(x: cx - rw / 2, y: srcH - (cy + rh / 2), width: rw, height: rh)      // repère Core Image

        let image = CIImage(cvPixelBuffer: sourceBuffer).cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        let scale = screenRect.height / rh
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: (screenRect.width / rw) / scale])
            .transformed(by: CGAffineTransform(translationX: screenRect.minX, y: screenRect.minY))
        var out = scaled.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: backdrop, kCIInputMaskImageKey: mask])

        // Position d'un point de la prise dans le canevas (nil s'il est hors de la région visible).
        func place(_ nx: Double, _ ny: Double) -> CGPoint? {
            let px = (CGFloat(nx) * srcW - region.minX) / rw
            let py = (CGFloat(ny) * srcH - (srcH - region.maxY)) / rh
            guard (0...1).contains(px), (0...1).contains(py) else { return nil }
            return CGPoint(x: screenRect.minX + px * screenRect.width, y: screenRect.maxY - py * screenRect.height)
        }

        // Ondes de clic.
        if spec.cursor.ripple {
            let scaleUI = canvas.width / 1920
            for k in clicks where s >= k.t && s <= k.t + 0.55 {
                guard let p = place(k.nx, k.ny) else { continue }
                let prog = (s - k.t) / 0.55
                let eased = 1 - pow(1 - prog, 3)
                let radius = (10 + 44 * eased) * scaleUI * CGFloat(spec.cursor.sizePercent) / 100
                let alpha = (1 - prog) * 0.9
                let ring = ringSprite
                    .transformed(by: CGAffineTransform(translationX: -64, y: -64))
                    .transformed(by: CGAffineTransform(scaleX: radius / 64, y: radius / 64))
                    .transformed(by: CGAffineTransform(translationX: p.x, y: p.y))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
                out = ring.composited(over: out)
            }
        }

        // Curseur.
        if spec.cursor.show, let cur, let p = place(cur.0, cur.1) {
            out = cursorSprite.transformed(by: CGAffineTransform(translationX: p.x, y: p.y - cursorHeight)).composited(over: out)
        }

        // Légende.
        for cap in spec.captions where s >= cap.t0 && s <= cap.t1 {
            let fade = min(1, min((s - cap.t0) / 0.2, (cap.t1 - s) / 0.25))
            let img = captionImage(cap.text)
            let placed = img.transformed(by: CGAffineTransform(translationX: (canvas.width - img.extent.width) / 2, y: canvas.height * 0.055))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, fade)))])
            out = placed.composited(over: out)
            break
        }
        return out.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func cursorPosition(at s: Double) -> (Double, Double)? {
        guard let first = pointer.first, s >= first.t - 0.5 else { return pointer.first.map { ($0.nx, $0.ny) } }
        var lo = 0, hi = pointer.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if pointer[mid].t <= s { lo = mid } else { hi = mid - 1 } }
        let a = pointer[lo]
        guard lo + 1 < pointer.count else { return (a.nx, a.ny) }
        let b = pointer[lo + 1]
        let f = b.t > a.t ? min(1, max(0, (s - a.t) / (b.t - a.t))) : 0
        return (a.nx + (b.nx - a.nx) * f, a.ny + (b.ny - a.ny) * f)
    }

    private func captionImage(_ text: String) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let cached = captionCache[text] { return cached }
        let fontSize = canvas.height * (spec.canvas.fill ? 0.026 : 0.034)
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let maxWidth = canvas.width * 0.82
        let setter = CTFramesetterCreateWithAttributedString(str)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let padX = fontSize * 0.9, padY = fontSize * 0.55
        let size = CGSize(width: ceil(fit.width + 2 * padX), height: ceil(fit.height + 2 * padY))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.78))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil))
        ctx.fillPath()
        let path = CGPath(rect: CGRect(x: padX, y: padY, width: fit.width, height: fit.height), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), ctx)
        let image = CIImage(cgImage: ctx.makeImage()!)
        captionCache[text] = image
        return image
    }

    // MARK: Sprites

    static func roundedMask(rect: CGRect, canvas: CGSize, radius: CGFloat, color: NSColor) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        return CIImage(cgImage: ctx.makeImage()!)
    }

    static func cursorImage(height: CGFloat) -> CIImage {
        let scale = height / 22
        let w = ceil(15 * scale) + 4, h = ceil(22 * scale) + 4
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        // Flèche système simplifiée : pointe en haut à gauche, contour sombre.
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 2 + x * scale, y: h - 2 - y * scale) }
        let path = CGMutablePath()
        path.move(to: pt(0, 0)); path.addLine(to: pt(0, 16)); path.addLine(to: pt(4, 12.5)); path.addLine(to: pt(7, 19.5))
        path.addLine(to: pt(10, 18.2)); path.addLine(to: pt(7.2, 11.5)); path.addLine(to: pt(12.5, 11.5)); path.closeSubpath()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        ctx.setLineWidth(1.3 * scale); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.drawPath(using: .fillStroke)
        return CIImage(cgImage: ctx.makeImage()!)
    }

    static func ringImage() -> CIImage {
        let size = 128
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: CGRect(x: 6, y: 6, width: 116, height: 116))
        return CIImage(cgImage: ctx.makeImage()!)
    }
}

// MARK: - Compositeur AVFoundation

final class FinishingInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let context: FinishingContext

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, context: FinishingContext) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.context = context
    }
}

final class FinishingCompositor: NSObject, AVVideoCompositing {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "mtapes.compositor", qos: .userInitiated, attributes: .concurrent)

    var sourcePixelBufferAttributes: [String: Any]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? FinishingInstruction,
                      let id = (instruction.requiredSourceTrackIDs?.first as? NSNumber)?.int32Value,
                      let source = request.sourceFrame(byTrackID: id),
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "mTAPES", code: 1, userInfo: [NSLocalizedDescriptionKey: "image source absente"]))
                    return
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                let image = instruction.context.render(sourceBuffer: source, outputTime: CMTimeGetSeconds(request.compositionTime))
                let t1 = CFAbsoluteTimeGetCurrent()
                Self.ciContext.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.context.canvas),
                                      colorSpace: CGColorSpace(name: instruction.context.outputP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
                if ProcessInfo.processInfo.environment["MTAPES_PROFILE"] != nil { Profile.add(graph: t1 - t0, render: CFAbsoluteTimeGetCurrent() - t1) }
                request.finish(withComposedVideoFrame: output)
            }
        }
    }
}

// MARK: - Construction de la composition

public enum Finisher {
    /// Lit le calque de finition d'une prise (ou le calcule s'il n'existe pas) .
    public static func loadOrPlan(_ package: TapePackage, preset: FinishingPreset, ratio: String? = nil) throws -> FinishingSpec {
        if let data = try? Data(contentsOf: package.finishingURL), let spec = try? JSONDecoder().decode(FinishingSpec.self, from: data) { return spec }
        let spec = try plan(package, preset: preset, ratio: ratio)
        try save(spec, to: package)
        return spec
    }

    public static func plan(_ package: TapePackage, preset: FinishingPreset, ratio: String? = nil) throws -> FinishingSpec {
        let meta = try package.readMeta()
        let events = (try? EventLog.decode(Data(contentsOf: package.eventsURL))) ?? []
        return Planner.plan(.init(meta: meta, events: events), preset: preset, ratio: ratio)
    }

    public static func save(_ spec: FinishingSpec, to package: TapePackage) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(spec).write(to: package.finishingURL, options: .atomic)
    }

    /// Lecture en direct de la prise avec la finition appliquée (aperçu de l'éditeur) : le même graphe que l'export.
    public static func previewItem(_ package: TapePackage, spec: FinishingSpec) async throws -> AVPlayerItem {
        let built = try await build(package, spec: spec)
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition
        var duration: Double
        var audioMix: AVAudioMix?
        var hasAudio: Bool
    }

    /// Insère les pistes son aux seuls passages à vitesse normale (aux temps du film), avec des fondus de 30 ms aux coupes.
    static func addAudio(_ tracks: [TapeMeta.AudioTrack], package: TapePackage, meta: TapeMeta, spec: FinishingSpec,
                         composition: AVMutableComposition, sourceDuration: Double) async throws -> AVAudioMix? {
        let timeline = spec.timeline(sourceDuration: sourceDuration)
        let hasMic = tracks.contains { $0.kind == "mic" }
        let cfg = spec.audio ?? FinishingSpec.Audio()
        guard cfg.enabled else { return nil }
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48000) }
        var params: [AVMutableAudioMixInputParameters] = []
        for t in tracks {
            let url = package.url.appendingPathComponent(t.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first,
                  let dst = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let audioDuration = CMTimeGetSeconds(try await asset.load(.duration))
            let offset = t.start - meta.firstFramePTS                       // début du son, en secondes de la prise
            let gain = Float(min(2, max(0, t.kind == "mic" ? cfg.micGain : (hasMic ? cfg.systemGain : min(1, cfg.systemGain / 0.7)))))
            let p = AVMutableAudioMixInputParameters(track: dst)
            var inserted = false
            for piece in timeline.pieces where abs(piece.factor - 1) < 1e-6 {
                var a0 = piece.s0 - offset, a1 = piece.s1 - offset
                let shift = max(0, -a0)
                a0 += shift; a1 = min(a1, audioDuration)
                guard a1 - a0 > 0.06 else { continue }
                let at = piece.c0 + shift
                try dst.insertTimeRange(CMTimeRange(start: cm(a0), duration: cm(a1 - a0)), of: src, at: cm(at))
                let fade = 0.03
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: cm(at), duration: cm(fade)))
                p.setVolume(gain, at: cm(at + fade))
                p.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0, timeRange: CMTimeRange(start: cm(at + (a1 - a0) - fade), duration: cm(fade)))
                inserted = true
            }
            if inserted { params.append(p) } else { composition.removeTrack(dst) }
        }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    static func build(_ package: TapePackage, spec: FinishingSpec, withAudio: Bool = true) async throws -> Built {
        let meta = try package.readMeta()
        let events = (try? EventLog.decode(Data(contentsOf: package.eventsURL))) ?? []
        let pointer = PointerTrack.decode((try? Data(contentsOf: package.pointerURL)) ?? Data()) ?? []

        let asset = AVURLAsset(url: package.rawURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EngineError.noFrames }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EngineError.noFrames }
        try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        for sp in spec.speeds.sorted(by: { $0.t0 > $1.t0 }) where sp.factor > 0 && sp.t1 > sp.t0 && sp.t0 < seconds {
            let t0 = max(0, sp.t0), t1 = min(seconds, sp.t1)
            composition.scaleTimeRange(CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600), duration: CMTime(seconds: t1 - t0, preferredTimescale: 600)),
                                       toDuration: CMTime(seconds: (t1 - t0) / sp.factor, preferredTimescale: 600))
        }

        let videoDuration = composition.duration
        var audioMix: AVAudioMix?
        if withAudio, let tracks = meta.audio, !tracks.isEmpty {
            audioMix = try await addAudio(tracks, package: package, meta: meta, spec: spec, composition: composition, sourceDuration: seconds)
        }
        let hasAudio = !composition.tracks(withMediaType: .audio).isEmpty

        let context = FinishingContext(spec: spec, meta: meta, sourceSize: size, sourceDuration: seconds, events: events, pointerSamples: pointer)
        let video = AVMutableVideoComposition()
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        video.renderSize = CGSize(width: spec.canvas.width, height: spec.canvas.height)
        video.customVideoCompositorClass = FinishingCompositor.self
        if context.outputP3 {                       // espace de travail du compositeur : Display P3 (sinon AVFoundation ramène les images en Rec. 709)
            video.colorPrimaries = AVVideoColorPrimaries_P3_D65
            video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        video.instructions = [FinishingInstruction(timeRange: CMTimeRange(start: .zero, duration: videoDuration), trackID: compTrack.trackID, context: context)]
        return Built(composition: composition, videoComposition: video, duration: CMTimeGetSeconds(videoDuration), audioMix: audioMix, hasAudio: hasAudio)
    }
}

/// Mesure de rendu (MTAPES_PROFILE=1) : temps moyen de construction du graphe Core Image et de son rendu par image.
enum Profile {
    nonisolated(unsafe) private static var graph = 0.0, render = 0.0, n = 0
    private static let lock = NSLock()
    static func add(graph g: Double, render r: Double) {
        lock.lock(); graph += g; render += r; n += 1
        if n % 100 == 0 { FileHandle.standardError.write(Data(String(format: "[profil] %d images : graphe %.1f ms, rendu %.1f ms par image\n", n, graph / Double(n) * 1000, render / Double(n) * 1000).utf8)) }
        lock.unlock()
    }
}
