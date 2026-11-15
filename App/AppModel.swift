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
        case idle
        case starting          // entre le clic et la première image : aucun second départ possible
        case recording, finishing
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
    /// Problème signalé par le moteur pendant la prise (flux coupé, plus d'images) ; texte déjà traduit.
    @Published var problem: String?
    /// Un résultat (ou une erreur) est arrivé pendant que la fenêtre n'était pas à l'écran : l'icône de la barre de menus le signale.
    @Published var unseen: Bool = false
    @Published var lastSummary: TapeSummary?

    private var session: RecordingSession?
    private var ticker: Timer?
    private var startedAt = Date()
    private var stopWhenStarted = false

    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/mTAPES", isDirectory: true)
    static let shortcutLabel = "⌥⌘R"

    var isBusy: Bool { phase == .starting || phase == .recording || phase == .finishing }

    /// « Une fenêtre » sans fenêtre choisie : on ne filme jamais l'écran entier à la place.
    var canRecord: Bool { !(kind == .window && selectedWindow == nil) }

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

    /// Raccourci et menu : démarre ou arrête. Pendant le départ, un second appui demande l'arrêt dès que la prise existe.
    func toggle() {
        switch phase {
        case .recording: stop()
        case .starting: stopWhenStarted = true
        case .finishing: break
        default: start()
        }
    }

    func start() {
        guard !isBusy else { return }
        guard canRecord else {
            phase = .failed(L.t("err.window.none"))
            return
        }
        screenAllowed = Permissions.screenRecording
        problem = nil
        stopWhenStarted = false
        phase = .starting                              // posé avant toute attente : un second déclenchement est ignoré
        Task { [weak self] in
            guard let self else { return }
            do {
                var options = CaptureOptions()
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                options.name = "\(L.t("take.name")) \(f.string(from: Date()))"
                options.origin = "manual"
                let target: CaptureTarget = (kind == .window && selectedWindow != nil) ? .window(id: selectedWindow!) : .display(index: nil)
                let s = try await Recorder.start(target: target, options: options, outputDirectory: Self.outputDirectory)
                s.onProblem = { [weak self] p in Task { @MainActor in self?.problem = Self.describe(p) } }
                session = s
                startedAt = Date(); elapsed = 0
                phase = .recording
                ticker?.invalidate()
                ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.elapsed = Date().timeIntervalSince(self.startedAt)
                    }
                }
                if stopWhenStarted { stop() }
            } catch {
                screenAllowed = Permissions.screenRecording
                fail(error)
            }
        }
    }

    func stop() {
        guard phase == .recording, let s = session else { return }
        ticker?.invalidate(); ticker = nil
        phase = .finishing
        Task { [weak self] in
            guard let self else { return }
            do {
                let (package, meta) = try await s.stop()
                let summary = TapeSummary(url: package.url, seconds: meta.durationSeconds, bytes: meta.stats.bytes,
                                          frames: meta.stats.framesWritten, dropped: meta.stats.framesDropped)
                lastSummary = summary
                unseen = true
                phase = .done(summary)
            } catch {
                fail(error)
            }
            session = nil
        }
    }

    /// Quitter pendant une prise : on termine proprement la prise avant de fermer (appelé par applicationShouldTerminate).
    func finishThenQuit(_ done: @escaping @MainActor () -> Void) {
        Task { [weak self] in
            guard let self else { return }
            if phase == .starting { stopWhenStarted = true }
            var waited = 0
            while phase == .starting && waited < 100 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
            if phase == .recording { stop() }
            waited = 0
            while phase == .finishing && waited < 300 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
            done()
        }
    }

    func reset() { phase = .idle }
    func markSeen() { unseen = false }

    private func fail(_ error: Error) {
        phase = .failed(Self.explain(error))
        unseen = true
    }

    // MARK: Textes d'erreur (traduits, « ce qui s'est passé et comment s'en sortir »)

    static func explain(_ error: Error) -> String {
        if let e = error as? EngineError {
            switch e {
            case .screenRecordingDenied: return L.t("err.denied")
            case .targetNotFound: return L.t("err.notFound")
            case .noFrames: return L.t("err.noFrames")
            case .writerFailed: return L.t("err.write")
            case .diskLow: return L.t("err.disk")
            case .alreadyStopped: return L.t("err.generic")
            }
        }
        return L.t("err.generic")
    }

    static func describe(_ p: RecordingSession.Problem) -> String {
        switch p {
        case .streamStopped: return L.t("problem.stopped")
        case .noFrames: return L.t("problem.silent")
        case .writerFailed: return L.t("problem.write")
        }
    }

    // MARK: Formats

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        let number = String(format: mb < 10 ? "%.1f" : "%.0f", locale: L.locale, mb)
        return number + " " + L.t("unit.mb")
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
