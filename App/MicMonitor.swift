// mTAPES — indicateur de niveau du micro choisi, pour vérifier qu'il capte avant d'enregistrer.
import AVFoundation
import SwiftUI

/// Écoute le micro choisi (sans rien enregistrer) pendant que l'écran d'accueil est visible ; coupé dès qu'une prise commence,
/// car ScreenCaptureKit prend alors le micro à son compte.
@MainActor
final class MicMonitor: ObservableObject {
    @Published var level: Double = 0                  // 0…1 (−60 dB … 0 dB)
    @Published var denied = false
    @Published var quiet = false                      // aucun son depuis plusieurs secondes
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: Timer?
    private var quietTicks = 0
    private var generation = 0

    func start(deviceID: String?) {
        stop()
        if ProcessInfo.processInfo.environment["MTAPES_SKIP_MIC_MONITOR"] != nil { return }     // essais d'interface : ni écoute ni demande d'autorisation
        generation += 1
        let mine = generation
        Task {
            let allowed = await Permissions.ensureMicrophone()
            guard mine == generation else { return }
            denied = !allowed
            guard allowed else { return }
            let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
            let s = AVCaptureSession()
            let out = AVCaptureAudioDataOutput()
            guard s.canAddInput(input), s.canAddOutput(out) else { return }
            s.addInput(input); s.addOutput(out)
            session = s; output = out
            DispatchQueue.global(qos: .utility).async { s.startRunning() }
            quietTicks = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        if let s = session { DispatchQueue.global(qos: .utility).async { s.stopRunning() } }
        session = nil; output = nil
        level = 0; quiet = false
    }

    private func tick() {
        guard let out = output, let ch = out.connection(with: .audio)?.audioChannels.first else { return }
        let db = Double(ch.averagePowerLevel)
        let target = min(1, max(0, (db + 60) / 60))
        level = target > level ? target : level * 0.8 + target * 0.2          // montée vive, retombée douce
        quietTicks = target < 0.05 ? quietTicks + 1 : 0
        quiet = quietTicks > 40
    }
}
