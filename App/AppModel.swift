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
    /// « sleep » ou « lock » quand le système a interrompu la prise (elle est alors arrêtée et enregistrée telle quelle).
    @Published var systemStop: String?
    /// Mode d'usage : Simple (une fenêtre) ou Avancé (bibliothèque et pilotage par IA). Sans choix enregistré : Avancé, pour ne rien masquer à qui l'utilise déjà.
    enum UsageMode: String { case simple, advanced }
    @Published var mode: UsageMode = UsageMode(rawValue: UserDefaults.standard.string(forKey: "usageMode") ?? "") ?? .advanced {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "usageMode") }
    }
    @Published var setupDone: Bool = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }
    @Published var lastSummary: TapeSummary?
    /// Pilotage par IA (MCP) : désactivé par défaut ; tant qu'il est coché dans le menu, un socket privé accepte les commandes du même utilisateur.
    /// Accord par client MCP (nom annoncé à l'initialisation) : un client inconnu est mis en attente et ne peut rien faire avant votre accord.
    @Published var approvedClients: [String] = UserDefaults.standard.stringArray(forKey: "mcpApprovedClients") ?? []
    @Published var pendingClients: [String] = []
    func approve(_ client: String) {
        pendingClients.removeAll { $0 == client }
        if !approvedClients.contains(client) { approvedClients.append(client) }
        UserDefaults.standard.set(approvedClients, forKey: "mcpApprovedClients")
    }
    func revoke(_ client: String) {
        approvedClients.removeAll { $0 == client }
        UserDefaults.standard.set(approvedClients, forKey: "mcpApprovedClients")
    }
    /// Serveur HTTP local (clients sans ligne de commande) : désactivé par défaut, jeton obligatoire.
    @Published var mcpHTTPEnabled: Bool = UserDefaults.standard.bool(forKey: "mcpHTTPEnabled") {
        didSet {
            UserDefaults.standard.set(mcpHTTPEnabled, forKey: "mcpHTTPEnabled")
            RemoteControl.shared.applyHTTP(enabled: mcpHTTPEnabled)
        }
    }
    @Published var mcpEnabled: Bool = UserDefaults.standard.bool(forKey: "mcpEnabled") {
        didSet {
            UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled")
            RemoteControl.shared.apply(enabled: mcpEnabled)
        }
    }

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
        systemStop = nil
        phase = .starting                              // posé avant toute attente : un second déclenchement est ignoré
        let target: CaptureTarget = (kind == .window && selectedWindow != nil) ? .window(id: selectedWindow!) : .display(index: nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await beginTake(target: target, origin: "manual", client: nil, name: nil, profile: .balanced, maxSeconds: nil)
            } catch {
                screenAllowed = Permissions.screenRecording
                fail(error)
            }
        }
    }

    /// Démarre la prise ; l'appelant a déjà posé la phase `.starting`. Sert au bouton, au raccourci et au pilotage par IA.
    func beginTake(target: CaptureTarget, origin: String, client: String?, name: String?, profile: QualityProfile, maxSeconds: Int?) async throws {
        var options = CaptureOptions()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60).description
        options.name = "\(base?.isEmpty == false ? base! : L.t("take.name")) \(f.string(from: Date()))"
        options.origin = origin
        options.client = client
        options.profile = profile
        let s = try await Recorder.start(target: target, options: options, outputDirectory: Self.outputDirectory)
        s.onProblem = { [weak self] p in Task { @MainActor in self?.problem = Self.describe(p) } }
        session = s
        if case .window(let id) = target { markWindowID = id } else { markWindowID = nil }
        startedAt = Date(); elapsed = 0
        phase = .recording
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
        if let maxSeconds {
            Task { [weak self] in                      // garde-fou : une prise pilotée s'arrête seule
                try? await Task.sleep(nanoseconds: UInt64(max(5, maxSeconds)) * 1_000_000_000)
                guard let self, self.session === s, self.phase == .recording else { return }
                self.stop()
            }
        }
        if stopWhenStarted { stop() }
    }

    private var watching = false
    /// Veille du Mac, écran éteint, session verrouillée : le flux d'écran s'arrête de lui-même ; on termine donc la prise proprement tout de suite.
    func watchSystem() {
        guard !watching else { return }
        watching = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stopForSystem("sleep") } }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stopForSystem("sleep") } }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopForSystem("lock") }
        }
    }

    func stopForSystem(_ reason: String) {
        switch phase {
        case .recording: systemStop = reason; stop()
        case .starting: systemStop = reason; stopWhenStarted = true
        default: break
        }
    }

    func stop() {
        guard phase == .recording else { return }
        Task { _ = await finishTake() }
    }

    /// Termine la prise en cours et renvoie son résumé.
    @discardableResult
    func finishTake() async -> Result<TapeSummary, Error> {
        guard phase == .recording, let s = session else { return .failure(ControlError("Aucune prise en cours.")) }
        ticker?.invalidate(); ticker = nil
        phase = .finishing
        defer { session = nil }
        do {
            let (package, meta) = try await s.stop()
            let summary = TapeSummary(url: package.url, seconds: meta.durationSeconds, bytes: meta.stats.bytes,
                                      frames: meta.stats.framesWritten, dropped: meta.stats.framesDropped)
            lastSummary = summary
            unseen = true
            phase = .done(summary)
            return .success(summary)
        } catch {
            fail(error)
            return .failure(error)
        }
    }

    // MARK: Pilotage par IA (lu par RemoteControl)

    var currentSession: RecordingSession? { session }
    private(set) var markWindowID: UInt32?

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
