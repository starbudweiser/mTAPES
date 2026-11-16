import AVFoundation
import Foundation

/// Les micros du Mac (intégré, USB, Bluetooth, interface audio) : de quoi choisir la source de la voix.
public struct MicrophoneInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String                 // identifiant unique du périphérique (celui que ScreenCaptureKit attend)
    public var name: String
    public var isDefault: Bool
    public init(id: String, name: String, isDefault: Bool) { self.id = id; self.name = name; self.isDefault = isDefault }
}

public enum Microphones {
    public static func list() -> [MicrophoneInfo] {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        var seen = Set<String>()
        return found.filter { seen.insert($0.uniqueID).inserted }
            .map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
            .sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    /// Retrouve un micro par identifiant ou par nom (sans tenir compte de la casse).
    public static func find(_ key: String) -> MicrophoneInfo? {
        let all = list()
        return all.first { $0.id == key } ?? all.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }
}
