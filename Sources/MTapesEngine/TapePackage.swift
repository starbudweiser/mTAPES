import Foundation

/// Métadonnées d'une prise (`meta.json`). Format versionné, voir ARCHITECTURE.md §3.
public struct TapeMeta: Codable, Equatable {
    public struct Source: Codable, Equatable {
        public var kind: String                // display | window | app | zone
        public var displayID: UInt32?
        public var windowID: UInt32?
        public var windowTitle: String?
        public var appBundle: String?
        public var bounds: [Double]            // x, y, largeur, hauteur en points (repère écran, origine en haut à gauche)
        public var scale: Double               // pixels par point
        public init(kind: String, displayID: UInt32? = nil, windowID: UInt32? = nil, windowTitle: String? = nil,
                    appBundle: String? = nil, bounds: [Double], scale: Double) {
            self.kind = kind; self.displayID = displayID; self.windowID = windowID
            self.windowTitle = windowTitle; self.appBundle = appBundle; self.bounds = bounds; self.scale = scale
        }
    }

    /// Piste son enregistrée à part (`audio-system.mov`, `audio-mic.mov`) ; `start` = horloge hôte de la première trame sonore.
    public struct AudioTrack: Codable, Equatable {
        public var kind: String                // system | mic
        public var file: String
        public var start: Double
        public var duration: Double
        public init(kind: String, file: String, start: Double, duration: Double) { self.kind = kind; self.file = file; self.start = start; self.duration = duration }
    }

    public struct Stats: Codable, Equatable {
        public var framesComplete = 0          // images livrées par ScreenCaptureKit (contenu changé)
        public var framesIdle = 0              // notifications « rien n'a changé » (aucune image écrite)
        public var framesBlank = 0
        public var framesWritten = 0
        public var framesDropped = 0           // encodeur en retard : image perdue
        public var bytes: Int64 = 0
        public var firstFrameLatency = 0.0     // secondes entre la demande de départ et la première image
        public var stopLatency = 0.0           // secondes pour finir le fichier
        public init() {}
    }

    public var version = 1
    public var id: String
    public var name: String
    public var created: Date
    public var origin: String                  // manual | cli | mcp
    public var client: String?
    public var source: Source
    public var profile: String
    public var pixelFormat: String
    public var codec: String
    public var maxFPS: Int
    public var width: Int
    public var height: Int
    public var durationSeconds: Double
    public var firstFramePTS: Double           // secondes de l'horloge hôte ; origine des événements
    public var stats: Stats
    public var state: String?                  // recording | complete | failed (absent : prise ancienne)
    public var error: String?                  // cause d'un échec ou d'une coupure du flux
    public var colorSpace: String?             // srgb | p3 (absent : srgb)
    public var audio: [AudioTrack]?            // pistes son (absent : prise sans son)

    public init(id: String, name: String, created: Date, origin: String, client: String?, source: Source,
                profile: String, pixelFormat: String, codec: String, maxFPS: Int, width: Int, height: Int,
                durationSeconds: Double, firstFramePTS: Double, stats: Stats) {
        self.id = id; self.name = name; self.created = created; self.origin = origin; self.client = client
        self.source = source; self.profile = profile; self.pixelFormat = pixelFormat; self.codec = codec
        self.maxFPS = maxFPS; self.width = width; self.height = height; self.durationSeconds = durationSeconds
        self.firstFramePTS = firstFramePTS; self.stats = stats
    }
}

/// Événement d'une prise (`events.jsonl`, une ligne JSON par événement).
public struct TapeEvent: Codable, Equatable {
    public var t: Double                       // secondes depuis la première image
    public var kind: String                    // click | doubleclick | rightclick | drag | chapter | …
    public var x: Double?
    public var y: Double?
    public var button: String?
    public var source: String                  // detected | declared
    public var label: String?
    public init(t: Double, kind: String, x: Double? = nil, y: Double? = nil, button: String? = nil,
                source: String = "detected", label: String? = nil) {
        self.t = t; self.kind = kind; self.x = x; self.y = y; self.button = button
        self.source = source; self.label = label
    }
}

public enum EventLog {
    public static func encode(_ events: [TapeEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> [TapeEvent] {
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { try decoder.decode(TapeEvent.self, from: Data($0)) }
    }
}

/// Trajectoire du pointeur (`pointer.bin`) : en-tête de 8 octets puis triplets Float64 little-endian (t, x, y).
public enum PointerTrack {
    public static let magic = Array("MTPTRK01".utf8)

    public static func encode(_ samples: [(t: Double, x: Double, y: Double)]) -> Data {
        var data = Data(magic)
        data.reserveCapacity(magic.count + samples.count * 24)
        for s in samples {
            for v in [s.t, s.x, s.y] {
                var bits = v.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public static func decode(_ data: Data) -> [(t: Double, x: Double, y: Double)]? {
        guard data.count >= magic.count, Array(data.prefix(magic.count)) == magic else { return nil }
        let body = data.dropFirst(magic.count)
        guard body.count % 24 == 0 else { return nil }
        var out: [(Double, Double, Double)] = []
        out.reserveCapacity(body.count / 24)
        let base = body.startIndex
        func read(_ offset: Int) -> Double {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(body[base + offset + i]) << UInt64(8 * i) }
            return Double(bitPattern: bits)
        }
        for i in 0..<(body.count / 24) { out.append((read(i * 24), read(i * 24 + 8), read(i * 24 + 16))) }
        return out.map { (t: $0.0, x: $0.1, y: $0.2) }
    }
}

/// Dossier `<nom>.tape` : raw.mov, events.jsonl, pointer.bin, meta.json (finition.json viendra plus tard).
public struct TapePackage {
    public let url: URL
    public var rawURL: URL { url.appendingPathComponent("raw.mov") }
    public var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    public var pointerURL: URL { url.appendingPathComponent("pointer.bin") }
    public var metaURL: URL { url.appendingPathComponent("meta.json") }
    public var finishingURL: URL { url.appendingPathComponent("finition.json") }
    public var exportsURL: URL { url.appendingPathComponent("exports", isDirectory: true) }

    public init(url: URL) { self.url = url }

    /// Crée un dossier de prise neuf ; un nom déjà pris reçoit un suffixe numérique.
    public static func create(in directory: URL, name: String) throws -> TapePackage {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var candidate = directory.appendingPathComponent("\(safe).tape", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safe) \(n).tape", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return TapePackage(url: candidate)
    }

    public func writeMeta(_ meta: TapeMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    public func readMeta() throws -> TapeMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TapeMeta.self, from: Data(contentsOf: metaURL))
    }
}
