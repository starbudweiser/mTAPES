import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation

/// Horloge de référence : l'horloge hôte, la même que celle des horodatages de ScreenCaptureKit.
public enum HostClock {
    public static func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

/// Échantillonne le pointeur à ~120 Hz et détecte les clics, sans aucune autorisation :
/// `CGEvent(source: nil)` donne la position, `CGEventSource.buttonState` l'état des boutons.
public final class EventRecorder {
    private let queue = DispatchQueue(label: "mtapes.events", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var detector = ClickDetector()
    private var events: [TapeEvent] = []
    private var samples: [(t: Double, x: Double, y: Double)] = []
    private var lastPosition: CGPoint?

    public init() {}

    public func start(rate: Double = 120) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / rate)), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        let t = HostClock.now()
        guard let location = CGEvent(source: nil)?.location else { return }
        // On ne garde un échantillon que si le pointeur a bougé (ou toutes les 250 ms) : fichier léger.
        if lastPosition != location || samples.isEmpty || t - (samples.last?.t ?? 0) > 0.25 {
            samples.append((t, Double(location.x), Double(location.y)))
            lastPosition = location
        }
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let right = CGEventSource.buttonState(.combinedSessionState, button: .right)
        events.append(contentsOf: detector.feed(.init(t: t, x: Double(location.x), y: Double(location.y), left: left, right: right)))
    }

    /// Arrête l'échantillonnage ; les temps sont en secondes de l'horloge hôte (à rebaser sur la première image).
    public func stop() -> (events: [TapeEvent], samples: [(t: Double, x: Double, y: Double)]) {
        timer?.cancel()
        timer = nil
        var result: (events: [TapeEvent], samples: [(t: Double, x: Double, y: Double)]) = ([], [])
        queue.sync { result = (self.events, self.samples) }
        return result
    }
}

public enum Permissions {
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    public static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }
}
