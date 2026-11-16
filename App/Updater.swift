// mTAPES — mise à jour depuis les releases GitHub : recherche quotidienne, téléchargement, vérification (somme, signature Developer ID,
// identifiant de paquet, version), remplacement puis relance. Jamais pendant une prise ou un export. La recherche ne prend jamais le focus.
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String)
        case downloading
        case failed(String)
    }

    static let repo = "starbudweiser/mTAPES"
    static let teamID = "35KLMK53PN"                   // seule signature acceptée pour une mise à jour
    private let interval: TimeInterval = 24 * 3600

    @Published private(set) var state: State = .idle
    private var asset: (zip: ReleaseAsset, sha256: ReleaseAsset?)?
    private var checking = false

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var autoUpdate: Bool { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
    /// Une prise (démarrage, enregistrement, finalisation) ou un export (rendu) est en cours.
    var busy: Bool { AppModel.shared.isBusy || ActiveExports.count > 0 }
    /// Pas de recherche automatique en essai (variable SKYRIM_TOOLS_NO_UPDATE_CHECK) ni dans la version de développement.
    private var automaticAllowed: Bool {
        ProcessInfo.processInfo.environment["SKYRIM_TOOLS_NO_UPDATE_CHECK"] == nil && Bundle.main.bundleIdentifier?.hasSuffix(".dev") != true
    }

    /// Appelé régulièrement : une recherche par jour, et installation automatique dès qu'il n'y a plus ni prise ni export.
    func tick() {
        guard automaticAllowed, autoUpdate else { return }
        let last = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        if state == .idle || state == .upToDate, Date().timeIntervalSince(last) > interval { Task { await check() } }
        if !busy, case .available = state { Task { await install() } }
    }

    func check() async {
        guard !checking, state != .downloading else { return }
        checking = true; state = .checking
        defer { checking = false }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw UpdateError.noRelease }
            UserDefaults.standard.set(Date(), forKey: "updateLastCheck")
            guard UpdateLogic.isNewer(tag, than: currentVersion) else { state = .upToDate; return }
            let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> ReleaseAsset? in
                guard let n = a["name"] as? String, let u = a["browser_download_url"] as? String else { return nil }
                return ReleaseAsset(name: n, url: u)
            }
            guard let pick = UpdateLogic.pickAsset(assets) else { throw UpdateError.noRelease }
            asset = pick
            state = .available(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Télécharge la nouvelle version, la vérifie, puis remplace l'appli et la relance.
    func install() async {
        guard case .available(let version) = state, let asset, let url = URL(string: asset.zip.url) else { return }
        guard !busy else { return }                                  // jamais pendant une prise ou un export
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("mTAPES-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            if let sha = asset.sha256, let shaURL = URL(string: sha.url) {
                let (text, r) = try await URLSession.shared.data(from: shaURL)
                if (r as? HTTPURLResponse)?.statusCode == 200, let expected = UpdateLogic.parseSHA256(String(decoding: text, as: UTF8.self)) {
                    let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                    guard digest == expected else { throw UpdateError.badHash }
                }
            }
            let out = work.appendingPathComponent("out")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            let app = out.appendingPathComponent("mTAPES.app")
            try await Self.verify(app)
            guard !busy else { state = .available(version: version); return }     // une prise a démarré entre-temps
            try Self.swapAndRelaunch(new: app, work: work)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease, download, badHash, badSignature, badVersion
        var errorDescription: String? {
            switch self {
            case .noRelease: return L.t("upd.err.none")
            case .download: return L.t("upd.err.download")
            case .badHash: return L.t("upd.err.hash")
            case .badSignature: return L.t("upd.err.signature")
            case .badVersion: return L.t("upd.err.version")
            }
        }
    }

    /// La nouvelle appli doit être valide, signée par la même équipe (Developer ID), avoir le même identifiant et être plus récente.
    private static func verify(_ app: URL) async throws {
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = try await run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard info.contains("TeamIdentifier=\(teamID)") else { throw UpdateError.badSignature }
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = plist["CFBundleShortVersionString"] as? String,
              UpdateLogic.isNewer(v, than: Updater.shared.currentVersion) else { throw UpdateError.badVersion }
    }

    /// Un petit script détaché attend la fin de l'appli, remplace le paquet puis relance la nouvelle version en arrière-plan.
    private static func swapAndRelaunch(new: URL, work: URL) throws {
        let target = Bundle.main.bundlePath
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target)" && /usr/bin/ditto "\(new.path)" "\(target)" && /usr/bin/open -g "\(target)"
        rm -rf "\(work.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }     // terminate() peut rester sans effet derrière une fenêtre modale
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume(returning: text) }
                else { cont.resume(throwing: exe.hasSuffix("codesign") ? UpdateError.badSignature : UpdateError.download) }
            }
        }
    }
}

/// Fenêtre « Mises à jour » : case d'installation automatique, recherche manuelle, état.
struct UpdateView: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject var model: AppModel
    @AppStorage("autoUpdate") private var auto = true

    private var status: String {
        switch updater.state {
        case .idle: return L.t("upd.version", updater.currentVersion)
        case .checking: return L.t("upd.checking")
        case .upToDate: return L.t("upd.uptodate", updater.currentVersion)
        case .available(let v): return L.t("upd.available", v)
        case .downloading: return L.t("upd.downloading")
        case .failed(let e): return L.t("upd.failed", e)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Socle.C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Socle.M.space5) {
                Text(branded: "mTAPES").socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
                Text(L.t("upd.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                VStack(alignment: .leading, spacing: Socle.M.space3) {
                    Toggle(L.t("upd.auto"), isOn: $auto).toggleStyle(.switch).accessibilityLabel(L.t("upd.auto")).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                    Text(L.t("upd.auto.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Socle.M.space2) {
                        Button(L.t("upd.check")) { Task { await updater.check() } }
                            .buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                            .disabled(updater.state == .checking || updater.state == .downloading)
                        if case .available(let v) = updater.state {
                            Button(L.t("upd.install", v)) { Task { await updater.install() } }
                                .buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize()
                                .disabled(updater.busy)
                        }
                    }
                    Text(status).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                    if case .available = updater.state, updater.busy {
                        Text(L.t("upd.busy")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Socle.M.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            }
            .padding(Socle.M.space6)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
