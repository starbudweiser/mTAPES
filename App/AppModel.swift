// mTAPES — état de l'appli : cible choisie, prise en cours, résultat. Aucune fenêtre n'est ouverte ici.
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct TapeSummary: Equatable {
        var url: URL
        var seconds: Double
        var bytes: Int64
        var frames: Int
        var dropped: Int
    }

    enum Phase: Equatable {
        case idle, recording, finishing
        case done(TapeSummary)
        case failed(String)
    }

    enum Kind { case screen, window }

    @Published var phase: Phase = .idle
    @Published var kind: Kind = .screen
    @Published var windows: [TargetInfo] = []
    @Published var selectedWindow: UInt32?
    @Published var elapsed: TimeInterval = 0
    @Published var screenAllowed = Permissions.screenRecording

    private var session: RecordingSession?
    private var ticker: Timer?
    private var startedAt = Date()

    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/mTAPES", isDirectory: true)
    static let shortcutLabel = "⌥⌘R"

    var isBusy: Bool { phase == .recording || phase == .finishing }

    var recordingLabel: String {
        if kind == .window, let w = windows.first(where: { $0.id == selectedWindow }) {
            return L.t("rec.window", w.app ?? w.title)
        }
        return L.t("rec.screen")
    }

    // MARK: Cibles

    func refreshWindows() async {
        let own = Bundle.main.bundleIdentifier
        let all = (try? await TargetCatalog.list()) ?? []
        windows = all.filter { $0.kind == "window" && $0.onScreen && $0.bundle != own && !($0.title.isEmpty && ($0.app ?? "").isEmpty) }
        if selectedWindow == nil || !windows.contains(where: { $0.id == selectedWindow }) { selectedWindow = windows.first?.id }
        screenAllowed = Permissions.screenRecording
    }

    // MARK: Prise

    func toggle() {
        switch phase {
        case .recording: stop()
        case .finishing: break
        default: start()
        }
    }

    func start() {
        guard !isBusy else { return }
        screenAllowed = Permissions.screenRecording
        Task {
            do {
                var options = CaptureOptions()
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                options.name = "Prise \(f.string(from: Date()))"
                options.origin = "manual"
                let target: CaptureTarget = (kind == .window && selectedWindow != nil) ? .window(id: selectedWindow!) : .display(index: nil)
                let s = try await Recorder.start(target: target, options: options, outputDirectory: Self.outputDirectory)
                session = s
                startedAt = Date(); elapsed = 0
                phase = .recording
                ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.elapsed = Date().timeIntervalSince(self.startedAt)
                    }
                }
            } catch {
                screenAllowed = Permissions.screenRecording
                phase = .failed("\(error)")
            }
        }
    }

    func stop() {
        guard phase == .recording, let s = session else { return }
        ticker?.invalidate(); ticker = nil
        phase = .finishing
        Task {
            do {
                let (package, meta) = try await s.stop()
                phase = .done(TapeSummary(url: package.url, seconds: meta.durationSeconds, bytes: meta.stats.bytes,
                                          frames: meta.stats.framesWritten, dropped: meta.stats.framesDropped))
            } catch {
                phase = .failed("\(error)")
            }
            session = nil
        }
    }

    func reset() { phase = .idle }

    // MARK: Formats

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return String(format: mb < 10 ? "%.1f Mo" : "%.0f Mo", locale: L.locale, mb).replacingOccurrences(of: "Mo", with: L.lang == "fr" ? "Mo" : "MB")
    }

    // MARK: Essais sans fenêtre

    /// `--selftest` : prise de 3 s de l'écran principal, résultat imprimé, aucune fenêtre.
    func selftest() async {
        do {
            var options = CaptureOptions()
            options.name = "selftest"; options.origin = "cli"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-selftest-\(getpid())", isDirectory: true)
            let s = try await Recorder.start(target: .display(index: nil), options: options, outputDirectory: dir)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let (package, meta) = try await s.stop()
            print("SELFTEST OK \(package.url.path) | \(meta.stats.framesWritten) images, \(meta.stats.framesDropped) perdues, \(meta.stats.bytes) octets, \(String(format: "%.2f", meta.durationSeconds)) s")
            try? FileManager.default.removeItem(at: dir)
        } catch {
            print("SELFTEST ÉCHEC \(error)")
        }
    }
}
