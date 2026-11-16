import CoreGraphics
import Foundation

// Finition : une prise brute (.tape) + un calque non destructif `finition.json` (zooms, temps morts accélérés, légendes, curseur, cadre).
// Le brut n'est jamais modifié ; le calque se recalcule à volonté (Planner) et se retouche à la main.

public struct FinishingSpec: Codable, Equatable {
    public struct Canvas: Codable, Equatable {
        public var width: Int
        public var height: Int
        public var fill: Bool                 // false : la prise tient entière dans le cadre ; true : recadrage « remplir » (vertical)
        public var marginPercent: Double      // marge autour de la prise, en % de la largeur du canevas
        public var cornerRadius: Double       // en pixels du canevas
        public var shadow: Bool
        public var backgroundTop: [Double]    // RGB 0…1
        public var backgroundBottom: [Double]
        public init(width: Int, height: Int, fill: Bool, marginPercent: Double, cornerRadius: Double, shadow: Bool,
                    backgroundTop: [Double], backgroundBottom: [Double]) {
            self.width = width; self.height = height; self.fill = fill; self.marginPercent = marginPercent
            self.cornerRadius = cornerRadius; self.shadow = shadow; self.backgroundTop = backgroundTop; self.backgroundBottom = backgroundBottom
        }
    }

    public struct Cursor: Codable, Equatable {
        public var show: Bool
        public var sizePercent: Double        // 100 = 22 px à 1920 de large
        public var smoothing: Double          // constante de temps en secondes (0 : brut)
        public var ripple: Bool
        public init(show: Bool = true, sizePercent: Double = 140, smoothing: Double = 0.07, ripple: Bool = true) {
            self.show = show; self.sizePercent = sizePercent; self.smoothing = smoothing; self.ripple = ripple
        }
    }

    public struct Zoom: Codable, Equatable {
        public var t0: Double                 // début du plateau, en secondes de la prise
        public var t1: Double
        public var scale: Double
        public var fx: Double                 // centre, 0…1 dans l'image de la prise (origine en haut à gauche)
        public var fy: Double
        public var source: String             // "auto" | "manual"
        public init(t0: Double, t1: Double, scale: Double, fx: Double, fy: Double, source: String = "auto") {
            self.t0 = t0; self.t1 = t1; self.scale = scale; self.fx = fx; self.fy = fy; self.source = source
        }
    }

    public struct Speed: Codable, Equatable {
        public var t0: Double
        public var t1: Double
        public var factor: Double
        public init(t0: Double, t1: Double, factor: Double) { self.t0 = t0; self.t1 = t1; self.factor = factor }
    }

    public struct Caption: Codable, Equatable {
        public var t0: Double
        public var t1: Double
        public var text: String
        public init(t0: Double, t1: Double, text: String) { self.t0 = t0; self.t1 = t1; self.text = text }
    }

    public var version = 1
    public var preset: String
    public var fps: Int
    public var canvas: Canvas
    public var cursor: Cursor
    public var easeSeconds: Double
    public var zooms: [Zoom]
    public var speeds: [Speed]
    public var captions: [Caption]

    public init(preset: String, fps: Int, canvas: Canvas, cursor: Cursor = .init(), easeSeconds: Double = 0.45,
                zooms: [Zoom] = [], speeds: [Speed] = [], captions: [Caption] = []) {
        self.preset = preset; self.fps = fps; self.canvas = canvas; self.cursor = cursor; self.easeSeconds = easeSeconds
        self.zooms = zooms; self.speeds = speeds; self.captions = captions
    }
}

extension FinishingSpec {
    /// Mêmes retouches (zooms, accélérations, légendes, curseur), cadre et cadence de la destination demandée.
    public func adapted(to preset: FinishingPreset) -> FinishingSpec {
        guard self.preset != preset.rawValue else { return self }
        var s = self
        s.preset = preset.rawValue; s.fps = preset.fps; s.canvas = preset.canvas
        return s
    }
}

/// Préréglages de destination : un nom d'usage, un format, un cadre.
public enum FinishingPreset: String, CaseIterable {
    case readme      // page de présentation GitHub : 16:9, 1280 × 720, GIF léger ou MP4
    case release     // publication d'une version : 16:9, 1920 × 1080, MP4
    case short       // vidéo verticale pour les réseaux : 9:16, 1080 × 1920, MP4

    public var canvas: FinishingSpec.Canvas {
        let top = [0.23, 0.17, 0.42], bottom = [0.12, 0.31, 0.48]       // violet vers bleu, comme les maquettes
        switch self {
        case .readme: return .init(width: 1280, height: 720, fill: false, marginPercent: 5, cornerRadius: 12, shadow: true, backgroundTop: top, backgroundBottom: bottom)
        case .release: return .init(width: 1920, height: 1080, fill: false, marginPercent: 5, cornerRadius: 18, shadow: true, backgroundTop: top, backgroundBottom: bottom)
        case .short: return .init(width: 1080, height: 1920, fill: true, marginPercent: 4, cornerRadius: 28, shadow: true, backgroundTop: top, backgroundBottom: bottom)
        }
    }
    public var fps: Int { self == .readme ? 30 : 60 }
}

// MARK: - Temps

extension FinishingSpec {
    /// Correspondance temps de la prise (source) ↔ temps du film (après accélération des temps morts).
    public struct Timeline {
        struct Piece { var s0: Double; var s1: Double; var c0: Double; var factor: Double }
        var pieces: [Piece] = []
        public private(set) var outputDuration = 0.0

        public init(speeds: [Speed], sourceDuration: Double) {
            var cursor = 0.0, out = 0.0
            for sp in speeds.sorted(by: { $0.t0 < $1.t0 }) {
                let a = max(cursor, sp.t0), b = min(sourceDuration, sp.t1)
                guard b > a, sp.factor > 0 else { continue }
                if a > cursor { pieces.append(Piece(s0: cursor, s1: a, c0: out, factor: 1)); out += a - cursor }
                pieces.append(Piece(s0: a, s1: b, c0: out, factor: sp.factor)); out += (b - a) / sp.factor
                cursor = b
            }
            if sourceDuration > cursor { pieces.append(Piece(s0: cursor, s1: sourceDuration, c0: out, factor: 1)); out += sourceDuration - cursor }
            outputDuration = out
        }

        public func sourceTime(forOutput c: Double) -> Double {
            for p in pieces {
                let len = (p.s1 - p.s0) / p.factor
                if c < p.c0 + len || p.s1 == pieces.last?.s1 { return min(p.s1, p.s0 + max(0, c - p.c0) * p.factor) }
            }
            return pieces.last?.s1 ?? 0
        }

        public func outputTime(forSource s: Double) -> Double {
            for p in pieces where s <= p.s1 { return p.c0 + max(0, s - p.s0) / p.factor }
            return outputDuration
        }
    }

    public func timeline(sourceDuration: Double) -> Timeline { Timeline(speeds: speeds, sourceDuration: sourceDuration) }

    /// Zoom à l'instant `t` (secondes de la prise) : échelle et centre, avec entrée et sortie adoucies.
    public func zoomState(at t: Double) -> (scale: Double, fx: Double, fy: Double) {
        func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        var weightSum = 0.0, fx = 0.0, fy = 0.0, boost = 0.0
        for z in zooms {
            let e = max(0.01, easeSeconds)
            let w: Double
            if t < z.t0 { w = smooth((t - (z.t0 - e)) / e) } else if t <= z.t1 { w = 1 } else { w = smooth(1 - (t - z.t1) / e) }
            guard w > 0 else { continue }
            let amount = w * (z.scale - 1)
            boost = max(boost, amount)
            weightSum += amount; fx += z.fx * amount; fy += z.fy * amount
        }
        guard weightSum > 0 else { return (1, 0.5, 0.5) }
        return (1 + boost, fx / weightSum, fy / weightSum)
    }
}

// MARK: - Planner

public enum Planner {
    public struct Input {
        public var meta: TapeMeta
        public var events: [TapeEvent]
        public init(meta: TapeMeta, events: [TapeEvent]) { self.meta = meta; self.events = events }
    }

    static let actionKinds: Set<String> = ["click", "doubleclick", "rightclick", "type", "key", "scroll", "drag"]

    /// Construit le calque de finition d'une prise : zooms regroupés sur les actions, temps morts accélérés, légendes tirées des libellés annoncés.
    public static func plan(_ input: Input, preset: FinishingPreset, ratio: String? = nil, maxScale: Double = 2.2) -> FinishingSpec {
        var canvas = preset.canvas
        if let ratio, ratio == "9:16", preset != .short { canvas = FinishingPreset.short.canvas }
        else if let ratio, ratio == "16:9", preset == .short { canvas = FinishingPreset.release.canvas }
        var spec = FinishingSpec(preset: preset.rawValue, fps: preset.fps, canvas: canvas)

        let duration = input.meta.durationSeconds
        let b = input.meta.source.bounds
        guard b.count == 4, b[2] > 0, b[3] > 0, duration > 0 else { return spec }

        // Actions positionnées, converties en coordonnées normalisées de la prise.
        struct Action { var t: Double; var nx: Double; var ny: Double }
        var actions: [Action] = []
        for e in input.events where actionKinds.contains(e.kind) {
            guard let x = e.x, let y = e.y else { continue }
            let nx = (x - b[0]) / b[2], ny = (y - b[1]) / b[3]
            guard (0...1).contains(nx), (0...1).contains(ny), e.t >= 0, e.t <= duration else { continue }
            actions.append(Action(t: e.t, nx: nx, ny: ny))
        }
        actions.sort { $0.t < $1.t }

        // Regroupement : des actions séparées de moins de 2 s forment un seul zoom.
        var groups: [[Action]] = []
        for a in actions {
            if var last = groups.last, let prev = last.last, a.t - prev.t < 2.0 {
                last.append(a); groups[groups.count - 1] = last
            } else { groups.append([a]) }
        }
        for g in groups {
            let xs = g.map(\.nx), ys = g.map(\.ny)
            let spanX = (xs.max() ?? 0) - (xs.min() ?? 0), spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
            let span = max(spanX / 0.7, spanY / 0.7, 0.01)                 // la zone d'action tient dans 70 % de l'image visible
            let scale = min(maxScale, max(1.5, 1 / span))
            let t0 = max(0, g.first!.t - 0.15), t1 = min(duration, g.last!.t + 0.9)
            guard t1 - t0 >= 0.6 else { continue }
            spec.zooms.append(.init(t0: t0, t1: t1, scale: scale, fx: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, fy: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2))
        }

        // Temps morts : plus de 3 s sans action ni légende (hors des zooms) -> accéléré ×4, avec 0,8 s de marge de chaque côté.
        var marks = input.events.filter { actionKinds.contains($0.kind) || $0.source == "declared" }.map(\.t)
        marks.append(contentsOf: [0, duration])
        marks = Array(Set(marks)).sorted()
        for (a, c) in zip(marks, marks.dropFirst()) where c - a > 3.0 {
            let s0 = a + 0.8, s1 = c - 0.8
            if s1 - s0 > 1.0 { spec.speeds.append(.init(t0: s0, t1: s1, factor: 4)) }
        }

        // Légendes : libellés annoncés par l'IA (jamais inventés).
        for e in input.events where e.source == "declared" {
            guard let label = e.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, e.t <= duration else { continue }
            spec.captions.append(.init(t0: max(0, e.t - 0.1), t1: min(duration, e.t + 2.4), text: label))
        }
        spec.captions.sort { $0.t0 < $1.t0 }
        return spec
    }
}
