import CoreGraphics
import CoreVideo
import Foundation

/// Profil d'enregistrement : un seul choix règle le moteur (voir ARCHITECTURE.md §10).
public enum QualityProfile: String, Codable, CaseIterable {
    case light, balanced, max

    /// Qualité constante demandée à l'encodeur (0…1).
    public var videoQuality: Double {
        switch self {
        case .light: return 0.50
        case .balanced: return 0.65
        case .max: return 0.75
        }
    }

    /// Cadence maximale demandée à ScreenCaptureKit ; la capture reste adaptative en dessous.
    public var maxFPS: Int {
        switch self {
        case .light: return 30
        case .balanced, .max: return 60
        }
    }

    /// Image clé au plus toutes les N secondes (aperçu et défilement fluides dans la finition).
    public var keyFrameInterval: Double { 1.0 }
}

/// Format de pixel demandé à ScreenCaptureKit.
public enum PixelFormatChoice: String, Codable, CaseIterable {
    case yuv420 = "420v"      // 4:2:0 8 bits : évite la conversion couleur, HEVC Main
    case yuv420ten = "x420"   // 4:2:0 10 bits : HEVC Main10 (à valider selon le Mac)
    case bgra = "BGRA"        // repli

    public var cvFormat: OSType {
        switch self {
        case .yuv420: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv420ten: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .bgra: return kCVPixelFormatType_32BGRA
        }
    }

    public var isTenBit: Bool { self == .yuv420ten }
}

public enum Geometry {
    /// Dimension en pixels, arrondie au pair inférieur (exigence des codecs 4:2:0), au moins 2.
    public static func evenPixels(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return max(2, rounded - (rounded % 2))
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case screenRecordingDenied
    case targetNotFound(String)
    case writerFailed(String)
    case noFrames
    case alreadyStopped

    public var description: String {
        switch self {
        case .screenRecordingDenied:
            return "Autorisation « Enregistrement de l'écran » absente pour ce programme (Réglages Système > Confidentialité et sécurité)."
        case .targetNotFound(let what): return "Cible introuvable : \(what)"
        case .writerFailed(let why): return "Écriture vidéo impossible : \(why)"
        case .noFrames: return "Aucune image reçue : l'écran n'a pas été capturé."
        case .alreadyStopped: return "La prise est déjà arrêtée."
        }
    }
}
