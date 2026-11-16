import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Montage automatique par IA : l'IA branchée (celle de l'utilisateur, donc sans coût en plus) lit un résumé compact de la prise
// (`summary`), éventuellement quelques images, puis renvoie ses décisions (`apply`) : zooms, temps accélérés, légendes.
// Tout ce qu'elle envoie est validé et borné ici : une IA qui se trompe ne peut produire ni film cassé ni coupe hors de la prise.

public enum Montage {
    public static let maxZooms = 40, maxSpeeds = 40, maxCaptions = 60, maxEventsInSummary = 200

    static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// Résumé lisible d'une prise : durée, cadre, événements (positions en 0…1 de l'image de la prise), plan courant.
    public static func summary(_ package: TapePackage) throws -> [String: Any] {
        let meta = try package.readMeta()
        let events = (try? EventLog.decode(Data(contentsOf: package.eventsURL))) ?? []
        let b = meta.source.bounds
        let geometry = GeometryTrack(meta: meta, events: events)
        var list: [[String: Any]] = []
        for e in events.filter({ $0.kind != "bounds" }).sorted(by: { $0.t < $1.t }).prefix(maxEventsInSummary) {
            var row: [String: Any] = ["t": r2(e.t), "kind": e.kind, "by": e.source]
            if let x = e.x, let y = e.y, b.count == 4, b[2] > 0, b[3] > 0 {
                let (nx, ny) = geometry.normalize(x: x, y: y, at: e.t)
                row["x"] = r2(nx); row["y"] = r2(ny)
                if !(0...1).contains(nx) || !(0...1).contains(ny) { row["outside"] = true }   // hors de l'image filmée : à ne pas zoomer
            }
            if let l = e.label, !l.isEmpty { row["label"] = l }
            list.append(row)
        }
        var out: [String: Any] = [
            "duration_s": r2(meta.durationSeconds),
            "source": ["kind": meta.source.kind, "title": meta.source.windowTitle ?? "", "aspect": b.count == 4 && b[3] > 0 ? r2(b[2] / b[3]) : 0],
            "events": list,
            "events_total": events.count,
            "coordinates": "x and y are 0...1 across the filmed image (0,0 = top-left), the same system tapes_apply_plan uses for zoom centres.",
        ]
        if events.count > maxEventsInSummary { out["events_truncated"] = true }
        if let tracks = meta.audio, !tracks.isEmpty {
            out["audio"] = tracks.map { $0.kind }
            out["audio_note"] = "The take has sound. It is kept at normal speed only: a sped-up stretch is muted, so never speed up a part where someone speaks."
        }
        if let data = try? Data(contentsOf: package.finishingURL), let spec = try? JSONDecoder().decode(FinishingSpec.self, from: data) {
            out["current_plan"] = describe(spec, duration: meta.durationSeconds)
        }
        return out
    }

    public static func describe(_ spec: FinishingSpec, duration: Double) -> [String: Any] {
        [
            "preset": spec.preset, "canvas": "\(spec.canvas.width)x\(spec.canvas.height)",
            "film_duration_s": r2(spec.timeline(sourceDuration: duration).outputDuration),
            "zooms": spec.zooms.map { ["from_s": r2($0.t0), "to_s": r2($0.t1), "scale": r2($0.scale), "x": r2($0.fx), "y": r2($0.fy), "by": $0.source] },
            "sped_up": spec.speeds.map { ["from_s": r2($0.t0), "to_s": r2($0.t1), "factor": r2($0.factor)] },
            "captions": spec.captions.map { ["from_s": r2($0.t0), "to_s": r2($0.t1), "text": $0.text] },
        ]
    }

    /// Applique les décisions de l'IA. Les sections absentes gardent le plan en place (ou le plan automatique). `warnings` liste chaque correction faite.
    public static func apply(_ package: TapePackage, preset: FinishingPreset, ratio: String?, arguments: [String: Any]) throws -> (FinishingSpec, [String]) {
        let meta = try package.readMeta()
        let duration = meta.durationSeconds
        var spec: FinishingSpec
        if let data = try? Data(contentsOf: package.finishingURL), let s = try? JSONDecoder().decode(FinishingSpec.self, from: data), arguments["preset"] == nil, ratio == nil {
            spec = s
        } else {
            spec = try Finisher.plan(package, preset: preset, ratio: ratio)
        }
        var warnings: [String] = []
        func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        func span(_ d: [String: Any], _ what: String, minLength: Double) -> (Double, Double)? {
            guard let a = num(d, "from_s"), let b = num(d, "to_s") else { warnings.append("\(what): from_s and to_s are required, item dropped."); return nil }
            let t0 = min(max(0, a), duration), t1 = min(max(0, b), duration)
            if t0 != a || t1 != b { warnings.append("\(what): times clamped to the take (0…\(r2(duration)) s).") }
            guard t1 - t0 >= minLength else { warnings.append("\(what): shorter than \(minLength) s, item dropped."); return nil }
            return (t0, t1)
        }

        if let zs = arguments["zooms"] as? [[String: Any]] {
            spec.zooms = []
            for z in zs.prefix(maxZooms) {
                guard let (t0, t1) = span(z, "zoom", minLength: 0.5) else { continue }
                let scale = min(3.0, max(1.1, num(z, "scale") ?? 1.8))
                if let s = num(z, "scale"), s != scale { warnings.append("zoom: scale \(s) clamped to \(scale) (allowed 1.1…3).") }
                spec.zooms.append(.init(t0: t0, t1: t1, scale: scale, fx: min(1, max(0, num(z, "x") ?? 0.5)), fy: min(1, max(0, num(z, "y") ?? 0.5)), source: "ai"))
            }
            if zs.count > maxZooms { warnings.append("zooms: only the first \(maxZooms) kept.") }
            spec.zooms.sort { $0.t0 < $1.t0 }
        }
        if let ss = arguments["speeds"] as? [[String: Any]] {
            spec.speeds = []
            for s in ss.prefix(maxSpeeds) {
                guard let (t0, t1) = span(s, "speed", minLength: 0.5) else { continue }
                let f = min(16, max(0.25, num(s, "factor") ?? 4))
                if let o = num(s, "factor"), o != f { warnings.append("speed: factor \(o) clamped to \(f) (allowed 0.25…16).") }
                spec.speeds.append(.init(t0: t0, t1: t1, factor: f))
            }
            spec.speeds.sort { $0.t0 < $1.t0 }
            var merged: [FinishingSpec.Speed] = []
            for s in spec.speeds {
                if let last = merged.last, s.t0 < last.t1 { warnings.append("speed: overlap at \(r2(s.t0)) s, the later range starts where the previous ends."); var n = s; n.t0 = last.t1; if n.t1 - n.t0 >= 0.5 { merged.append(n) } }
                else { merged.append(s) }
            }
            spec.speeds = merged
        }
        if let cs = arguments["captions"] as? [[String: Any]] {
            spec.captions = []
            for c in cs.prefix(maxCaptions) {
                guard let (t0, t1) = span(c, "caption", minLength: 0.5) else { continue }
                var text = (c["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { warnings.append("caption: empty text, item dropped."); continue }
                if text.count > 80 { text = String(text.prefix(80)); warnings.append("caption: text cut to 80 characters.") }
                spec.captions.append(.init(t0: t0, t1: t1, text: text))
            }
            spec.captions.sort { $0.t0 < $1.t0 }
        }
        if let cur = arguments["cursor"] as? [String: Any] {
            if let v = cur["show"] as? Bool { spec.cursor.show = v }
            if let v = cur["ripple"] as? Bool { spec.cursor.ripple = v }
            if let v = num(cur, "size_percent") { spec.cursor.sizePercent = min(300, max(50, v)) }
        }
        try Finisher.save(spec, to: package)
        return (spec, warnings)
    }

    /// Quelques images de la prise (JPEG, 640 px de large) pour que l'IA voie ce qu'elle monte. Réparties régulièrement, ou aux instants donnés.
    public static func frames(_ package: TapePackage, count: Int, times: [Double]? = nil) async throws -> [(t: Double, jpeg: Data)] {
        let meta = try package.readMeta()
        let duration = meta.durationSeconds
        guard duration > 0 else { return [] }
        let n = min(6, max(1, count))
        let instants = (times?.map { min(max(0, $0), duration) }.prefix(6).map { $0 }) ?? (0..<n).map { duration * (Double($0) + 0.5) / Double(n) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: package.rawURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var out: [(Double, Data)] = []
        for t in instants {
            guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            if CGImageDestinationFinalize(dest) { out.append((t, data as Data)) }
        }
        return out
    }

    /// Guide de montage donné à l'IA (prompt MCP « edit_demo », repris dans PROMPTING.md).
    public static let guide = """
    You are editing a screen demo recorded by mTAPES. Goal: a short, clear film where the viewer always sees what matters.
    1. Call tapes_summary (add frames=4 if you need to see the screen). Read the marks: each click/type/chapter has a time, a position (0-1) and your label.
    2. Zooms: one per action cluster. Centre on the action (x, y from the marks), scale 1.6-2.2 for a button or field, 1.3-1.5 for a region. Hold 1-3 s. No zoom during pure reading or waiting; never more than one zoom every ~3 s.
    3. Dead time: speed up every stretch with no action for more than 2 s (factor 3-8), keeping 0.5-1 s of normal speed on both sides. Never speed up a result the viewer must read (a finished export, a dialog).
    4. Captions: 2-6 words, imperative or noun phrase ("Choose a folder", "Export as GIF"), one per step, shown 1.5-2.5 s from the action. Reuse your own mark labels; do not invent features that are not on screen.
    5. Length: aim for 15-45 s for a README GIF, 30-90 s for a release film, under 45 s for a short. Cut tempo, not content.
    6. If the summary lists audio, the sound is kept only at normal speed: do not speed up a spoken part.
    7. Call tapes_apply_plan with zooms, speeds, captions (times in seconds of the RAW take). Read its warnings and film_duration_s, fix anything odd, then tapes_export.
    """
}
