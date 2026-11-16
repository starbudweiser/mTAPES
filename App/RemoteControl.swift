// mTAPES — pilotage par IA : reçoit les commandes du serveur MCP (`mtapes-cli mcp`) par un socket Unix privé.
// Désactivé par défaut (case « Pilotage par IA » du menu) : l'appli détient l'autorisation d'enregistrer l'écran,
// aucun autre programme ne doit pouvoir s'en servir sans l'accord explicite de l'utilisateur.
import AppKit
import Foundation

struct ControlError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

@MainActor
final class RemoteControl {
    static let shared = RemoteControl()
    private var server: ControlServer?
    private var httpServer: MCPHTTPServer?
    var httpPort: UInt16 { MCPHTTPPaths.port(dev: isDev) }
    var httpURL: String { "http://127.0.0.1:\(httpPort)/mcp" }
    var httpToken: String { (try? MCPHTTPPaths.loadOrCreateToken(dev: isDev)) ?? "" }

    /// Serveur HTTP local : mêmes outils, mêmes accords par client, jeton obligatoire.
    func applyHTTP(enabled: Bool) {
        if enabled {
            guard httpServer == nil, let token = try? MCPHTTPPaths.loadOrCreateToken(dev: isDev) else { return }
            let core = MCPCore { method, params in await RemoteControl.shared.handle(ControlRequest(id: 1, method: method, params: params)) }
            let s = MCPHTTPServer(port: httpPort, token: token, core: core)
            do { try s.start(); httpServer = s } catch { print("Serveur HTTP : démarrage impossible : \(error)") }
        } else {
            httpServer?.stop()
            httpServer = nil
        }
    }

    private var isDev: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false }

    func apply(enabled: Bool) {
        if enabled {
            guard server == nil else { return }
            let s = ControlServer(path: ControlPaths.socketPath(dev: isDev)) { request in
                await RemoteControl.shared.handle(request)
            }
            do { try s.start(); server = s } catch { print("Pilotage par IA : démarrage impossible : \(error)") }
        } else {
            server?.stop()
            server = nil
        }
    }

    // MARK: Requêtes

    func handle(_ request: ControlRequest) async -> ControlResponse {
        let model = AppModel.shared
        let p = request.params
        if request.method != "ping" {
            let who = p?["mcp_client"]?.string ?? p?["client"]?.string ?? "unknown"
            if !model.approvedClients.contains(who) {
                if !model.pendingClients.contains(who) { model.pendingClients.append(who) }
                return .failure(request.id, "The client \"\(who)\" is not approved yet. Ask the user to open the mTAPES menu-bar menu and choose \"Allow \(who)\" (Autoriser), then retry. Nothing was recorded.")
            }
        }
        do {
            switch request.method {
            case "ping":
                return ok(request, ["app": .string("mTAPES"), "phase": .string(phaseName(model))])

            case "authorize":
                return ok(request, ["authorized": .bool(true)])

            case "targets":
                return ok(request, try await targets(kind: p?["kind"]?.string))

            case "start":
                guard !model.isBusy else { throw ControlError("A take is already running (phase: \(phaseName(model))). Call tapes_stop first.") }
                let target = try parseTarget(p)
                let profile = QualityProfile(rawValue: p?["profile"]?.string ?? "balanced") ?? .balanced
                let audio = p?["audio"]?.string ?? "none"
                guard let color = ColorChoice(rawValue: p?["color"]?.string ?? "srgb") else { throw ControlError("color must be srgb or p3.") }
                guard ["none", "system", "mic", "both"].contains(audio) else { throw ControlError("audio must be none, system, mic or both.") }
                model.problem = nil
                model.systemStop = nil
                model.phase = .starting
                do {
                    try await model.beginTake(target: target, origin: "mcp", client: p?["client"]?.string, name: p?["name"]?.string,
                                              profile: profile, maxSeconds: p?["max_seconds"]?.int ?? 600,
                                              system: ["system", "both"].contains(audio), mic: ["mic", "both"].contains(audio), color: color)
                } catch {
                    model.screenAllowed = Permissions.screenRecording
                    model.phase = .failed(AppModel.explain(error))
                    throw ControlError("Could not start: \(error)")
                }
                return ok(request, ["tape_path": .string(model.currentSession?.packageURL.path ?? ""), "recording": .bool(true)])

            case "mark":
                guard model.phase == .recording, let session = model.currentSession else { throw ControlError("No take is recording. Call tapes_start first.") }
                let kind = p?["kind"]?.string ?? ""
                guard ["click", "doubleclick", "rightclick", "type", "scroll", "key", "chapter"].contains(kind) else {
                    throw ControlError("Unknown kind \"\(kind)\". Use click, doubleclick, rightclick, type, scroll, key or chapter.")
                }
                var x = p?["x"]?.double, y = p?["y"]?.double
                if kind != "chapter", (p?["space"]?.string ?? "screen") == "window" {
                    guard let id = model.markWindowID, let origin = windowOrigin(id) else {
                        throw ControlError("space=window needs a take started with target=window on a window that is still open.")
                    }
                    if let xx = x { x = xx + Double(origin.x) }
                    if let yy = y { y = yy + Double(origin.y) }
                }
                if kind == "chapter" { x = nil; y = nil }
                let t = session.mark(kind: kind, x: x, y: y, label: p?["label"]?.string)
                return ok(request, ["marked": .bool(true), "video_time_s": t.map { .number(($0 * 100).rounded() / 100) } ?? .null])

            case "status":
                var r: [String: JSONValue] = ["phase": .string(phaseName(model)), "elapsed_s": .number((model.elapsed * 10).rounded() / 10)]
                if let s = model.currentSession {
                    let st = s.liveStats
                    r["tape_path"] = .string(s.packageURL.path)
                    r["frames_written"] = .number(Double(st.framesWritten))
                    r["frames_refused"] = .number(Double(st.framesDropped))
                }
                if let problem = model.problem { r["problem"] = .string(problem) }
                if let why = model.systemStop {
                    r["stopped_by"] = .string(Self.stopReason(why))
                    if let last = model.lastSummary { r["tape_path"] = .string(last.url.path) }
                }
                return ok(request, r)

            case "stop":
                // Le système (veille, verrouillage) a déjà arrêté la prise : on rend la prise enregistrée au lieu d'une erreur.
                if model.phase != .recording, let why = model.systemStop, let s = model.lastSummary {
                    return ok(request, ["tape_path": .string(s.url.path), "duration_s": .number((s.seconds * 100).rounded() / 100),
                                        "megabytes": .number((Double(s.bytes) / 10_000).rounded() / 100), "frames": .number(Double(s.frames)),
                                        "frames_refused": .number(Double(s.dropped)), "stopped_by": .string(Self.stopReason(why))])
                }
                guard model.phase == .recording else { throw ControlError("No take is recording.") }
                switch await model.finishTake() {
                case .success(let s):
                    let events = (try? String(contentsOf: s.url.appendingPathComponent("events.jsonl"), encoding: .utf8))?.split(separator: "\n").count ?? 0
                    return ok(request, ["tape_path": .string(s.url.path), "duration_s": .number((s.seconds * 100).rounded() / 100),
                                        "megabytes": .number((Double(s.bytes) / 10_000).rounded() / 100), "frames": .number(Double(s.frames)),
                                        "frames_refused": .number(Double(s.dropped)), "events": .number(Double(events))])
                case .failure(let e):
                    throw ControlError("The take could not be finished: \(e)")
                }

            case "takes":
                return ok(request, takes(limit: p?["limit"]?.int ?? 10))

            default:
                throw ControlError("Unknown method \(request.method)")
            }
        } catch {
            return .failure(request.id, "\(error)")
        }
    }

    static func stopReason(_ why: String) -> String { why == "lock" ? "screen locked" : (why == "display" ? "display resolution changed" : "Mac sleep") }

    private func ok(_ r: ControlRequest, _ result: [String: JSONValue]) -> ControlResponse { .init(id: r.id, ok: true, result: .object(result)) }
    private func ok(_ r: ControlRequest, _ result: JSONValue) -> ControlResponse { .init(id: r.id, ok: true, result: result) }

    private func phaseName(_ m: AppModel) -> String {
        switch m.phase {
        case .idle, .done, .failed: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .finishing: return "finishing"
        }
    }

    private func parseTarget(_ p: JSONValue?) throws -> CaptureTarget {
        let display = p?["display"]?.int
        switch p?["target"]?.string ?? "display" {
        case "display": return .display(index: display)
        case "window":
            guard let id = p?["window_id"]?.int else { throw ControlError("target=window needs window_id (see tapes_list_targets).") }
            return .window(id: UInt32(id))
        case "app":
            guard let bundle = p?["app_bundle"]?.string else { throw ControlError("target=app needs app_bundle.") }
            return .app(bundleID: bundle, displayIndex: display)
        case "zone":
            guard let z = p?["zone"], let x = z["x"]?.double, let y = z["y"]?.double, let w = z["width"]?.double, let h = z["height"]?.double else {
                throw ControlError("target=zone needs zone {x, y, width, height} in points.")
            }
            return .zone(displayIndex: display, rect: CGRect(x: x, y: y, width: w, height: h))
        default: throw ControlError("target must be display, window, app or zone.")
        }
    }

    private func targets(kind: String?) async throws -> JSONValue {
        let all = try await TargetCatalog.list()
        let own = Bundle.main.bundleIdentifier
        var rows: [JSONValue] = []
        var displayIndex = 0
        for t in all {
            if t.kind == "display" { displayIndex += 1 }
            if let kind, t.kind != kind { continue }
            if t.bundle == own { continue }
            if t.kind == "window" && (!t.onScreen || (t.title.isEmpty && (t.app ?? "").isEmpty)) { continue }
            var row: [String: JSONValue] = ["kind": .string(t.kind), "title": .string(t.title)]
            if t.kind == "display" { row["display"] = .number(Double(displayIndex)) }
            if t.kind == "window" { row["window_id"] = .number(Double(t.id)) }
            if let a = t.app { row["app"] = .string(a) }
            if let b = t.bundle { row["app_bundle"] = .string(b) }
            if !t.bounds.isEmpty { row["bounds"] = .array(t.bounds.map { .number($0) }) }
            rows.append(.object(row))
        }
        return .array(rows)
    }

    private func takes(limit: Int) -> JSONValue {
        let dir = AppModel.outputDirectory
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "tape" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var rows: [JSONValue] = []
        for u in urls.prefix(max(1, limit)) {
            guard let m = try? TapePackage(url: u).readMeta() else { continue }
            rows.append(.object(["path": .string(u.path), "name": .string(m.name), "origin": .string(m.origin), "state": .string(m.state ?? "complete"),
                                 "duration_s": .number((m.durationSeconds * 100).rounded() / 100),
                                 "megabytes": .number((Double(m.stats.bytes) / 10_000).rounded() / 100)]))
        }
        return .array(rows)
    }

    private func windowOrigin(_ id: UInt32) -> CGPoint? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return rect.origin
    }
}
