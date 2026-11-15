import CoreGraphics
import Foundation
import MTapesEngine

// mtapes : moteur d'enregistrement en ligne de commande (étape 1 de mTAPES).
// Aucune fenêtre, aucun focus : les essais et les mesures se font en arrière-plan.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        let valued: Set<String> = ["input", "q", "display", "window", "app", "zone", "seconds", "out", "name", "profile", "fps", "pixel"]
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if valued.contains(key), i + 1 < raw.count { options[key] = raw[i + 1]; i += 1 } else { flags.insert(key) }
            } else { positional.append(a) }
            i += 1
        }
    }

    func target() -> CaptureTarget {
        let displayIndex = options["display"].flatMap { Int($0) }
        if let zone = options["zone"] {
            let v = zone.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { fail("--zone attend x,y,largeur,hauteur (points)") }
            return .zone(displayIndex: displayIndex, rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
        if let w = options["window"] { guard let id = UInt32(w) else { fail("--window attend un numéro de fenêtre") }; return .window(id: id) }
        if let a = options["app"] { return .app(bundleID: a, displayIndex: displayIndex) }
        return .display(index: displayIndex)
    }

    func captureOptions() -> CaptureOptions {
        var o = CaptureOptions()
        if let n = options["name"] { o.name = n }
        if let p = options["profile"] {
            guard let profile = QualityProfile(rawValue: p) else { fail("--profile : light, balanced ou max") }
            o.profile = profile
        }
        if let f = options["fps"] { o.maxFPS = Int(f) }
        if let px = options["pixel"] {
            guard let choice = PixelFormatChoice(rawValue: px) else { fail("--pixel : 420v, x420 ou BGRA") }
            o.pixelFormat = choice
        }
        return o
    }

    var outDir: URL {
        URL(fileURLWithPath: (options["out"] as NSString?)?.expandingTildeInPath ?? NSTemporaryDirectory() + "mtapes", isDirectory: true)
    }
    var seconds: Double { options["seconds"].flatMap { Double($0) } ?? 10 }
}

let usage = """
mtapes <commande>
  doctor                         diagnostic : autorisations, encodeur matériel, qualité constante
  targets                        écrans, fenêtres et applications que l'on peut filmer (JSON)
  record [cible] --seconds N     enregistre une prise .tape (--out DIR --name NOM --profile light|balanced|max)
  bench  [cible] --seconds N     enregistre et mesure : processeur, images, poids, délais (--keep garde la prise, --quality mesure SSIM/PSNR)
  encode-bench --input F.mov     réencode une séquence source avec un profil et mesure poids, vitesse, SSIM, PSNR
  info   CHEMIN.tape             affiche les métadonnées d'une prise
cible : --display N | --window ID | --app BUNDLE | --zone x,y,l,h   (par défaut : écran principal)
options moteur : --fps N --pixel 420v|x420|BGRA
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
let rest = Args(Array(args.dropFirst()))

func run() async {
    switch command {
    case "doctor":
        printJSON(await Doctor.run())

    case "targets":
        do { printJSON(try await TargetCatalog.list()) } catch { fail("\(error)") }

    case "record":
        do {
            let session = try await Recorder.start(target: rest.target(), options: rest.captureOptions(), outputDirectory: rest.outDir)
            try await Task.sleep(nanoseconds: UInt64(rest.seconds * 1_000_000_000))
            let (package, meta) = try await session.stop()
            print("Prise enregistrée : \(package.url.path)")
            printJSON(meta)
        } catch { fail("\(error)") }

    case "bench":
        do {
            let dir = rest.flags.contains("keep") ? rest.outDir : URL(fileURLWithPath: NSTemporaryDirectory() + "mtapes-bench-\(getpid())", isDirectory: true)
            var options = rest.captureOptions()
            let quality = rest.flags.contains("quality")
            if quality { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); options.referenceURL = dir.appendingPathComponent("reference.mov") }
            let (result, package) = try await Bench.run(target: rest.target(), options: options, seconds: rest.seconds, outputDirectory: dir)
            printJSON(result)
            if quality, let ref = options.referenceURL {
                do { printJSON(try QualityCheck.measure(raw: package.rawURL, reference: ref)) } catch { print("Qualité : \(error)") }
            }
            if rest.flags.contains("keep") { print("Prise gardée : \(package.url.path)") } else { try? FileManager.default.removeItem(at: dir) }
        } catch { fail("\(error)") }

    case "encode-bench":
        guard let input = rest.options["input"] else { fail("encode-bench attend --input source.mov") }
        do {
            let out = URL(fileURLWithPath: NSTemporaryDirectory() + "mtapes-enc-\(getpid()).mov")
            let opts = rest.captureOptions()
            let result = try await EncoderBench.run(input: URL(fileURLWithPath: input), output: out, profile: opts.profile, pixelFormat: opts.pixelFormat, quality: rest.options["q"].flatMap { Double($0) })
            printJSON(result)
            printJSON(try QualityCheck.measure(raw: out, reference: URL(fileURLWithPath: input)))
            try? FileManager.default.removeItem(at: out)
        } catch { fail("\(error)") }

    case "info":
        guard let path = rest.positional.first else { fail("info attend le chemin d'une prise .tape") }
        do { printJSON(try TapePackage(url: URL(fileURLWithPath: path)).readMeta()) } catch { fail("\(error)") }

    default:
        print(usage)
    }
}

await run()
