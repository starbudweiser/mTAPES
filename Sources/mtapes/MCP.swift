import Foundation
#if canImport(MTapesEngine)
import MTapesEngine
#endif

// Serveur MCP (stdio) : `mtapes mcp`. Il ne filme rien lui-même : il transmet chaque outil à l'appli mTAPES (qui détient
// l'autorisation d'enregistrer l'écran) par un socket Unix privé, et la lance en arrière-plan si besoin.

struct MCPServer {
    let dev: Bool
    var bundleID: String { dev ? "fr.stephan.mtapes.dev" : "fr.stephan.mtapes" }
    var socketPath: String { ControlPaths.socketPath(dev: dev) }

    static let instructions = """
    mTAPES records the user's screen silently and produces a raw take (.tape). Typical flow: tapes_list_targets (optional) -> tapes_start -> \
    do the work, calling tapes_mark right after EACH action you perform (click, type, scroll, key) with its screen position and a short human label, \
    and tapes_mark kind=chapter at the start of each phase -> tapes_stop. Marks become the editing script: zooms and captions follow them, so label them well \
    (e.g. "Choose a folder", not "click"). Coordinates are in points; use space=window for positions relative to the filmed window's top-left corner. \
    Never leave a take running: always call tapes_stop (a take also stops by itself after max_seconds, default 600). One take at a time.
    """

    func tools() -> [[String: Any]] {
        func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        return [
            ["name": "tapes_list_targets",
             "description": "List what can be filmed: displays (index, size), open windows (window_id, app, title, bounds) and running applications. Use the window_id with tapes_start target=window.",
             "inputSchema": schema(["kind": ["type": "string", "enum": ["display", "window", "app"], "description": "Only this kind (default: all)."]])],
            ["name": "tapes_start",
             "description": "Start a take. target=display films a whole screen (display = 1-based index, default main screen); target=window films one window even if other windows cover it (window_id from tapes_list_targets); target=app films one application's windows (app_bundle); target=zone films a rectangle of a screen (zone in points). Returns the take path. Fails if a take is already running or if the user has not enabled AI control in mTAPES.",
             "inputSchema": schema([
                "target": ["type": "string", "enum": ["display", "window", "app", "zone"], "description": "What to film (default display)."],
                "display": ["type": "integer", "description": "1-based display index (display, app and zone targets)."],
                "window_id": ["type": "integer", "description": "Window id from tapes_list_targets (target=window)."],
                "app_bundle": ["type": "string", "description": "Bundle identifier, e.g. com.apple.TextEdit (target=app)."],
                "zone": ["type": "object", "description": "Rectangle in points, origin top-left of the display.", "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]]],
                "name": ["type": "string", "description": "Short name for the take (e.g. the feature being demonstrated)."],
                "profile": ["type": "string", "enum": ["light", "balanced", "max"], "description": "Quality profile (default balanced)."],
                "max_seconds": ["type": "integer", "description": "Safety limit; the take stops by itself after this many seconds (default 600)."],
                "client": ["type": "string", "description": "Your name (e.g. Claude Code), recorded in the take."],
             ])],
            ["name": "tapes_mark",
             "description": "Announce an action you just performed so the editor can zoom on it and caption it. kind: click, doubleclick, rightclick, type, scroll, key, or chapter (a section title, no position). x,y: screen points (or window-relative with space=window). label: short human description. Returns the time in the video.",
             "inputSchema": schema([
                "kind": ["type": "string", "enum": ["click", "doubleclick", "rightclick", "type", "scroll", "key", "chapter"]],
                "x": ["type": "number"], "y": ["type": "number"],
                "space": ["type": "string", "enum": ["screen", "window"], "description": "Coordinate space (default screen)."],
                "label": ["type": "string", "description": "Short caption, e.g. \"Choose a folder\"."],
             ], required: ["kind"])],
            ["name": "tapes_status",
             "description": "State of the current take: phase (idle, starting, recording, finishing), elapsed seconds, frames written, and any problem reported by the recorder (stream cut, no frames).",
             "inputSchema": schema([:])],
            ["name": "tapes_stop",
             "description": "Stop the current take and finish the file. Returns the take path, duration, size and number of marks. Always call this when the demonstration is over.",
             "inputSchema": schema([:])],
            ["name": "tapes_list",
             "description": "List recent takes in ~/Movies/mTAPES (newest first) with name, duration, size, origin and state.",
             "inputSchema": schema(["limit": ["type": "integer", "description": "Maximum number of takes (default 10)."]])],
        ]
    }

    static let methodForTool: [String: String] = [
        "tapes_list_targets": "targets", "tapes_start": "start", "tapes_mark": "mark",
        "tapes_status": "status", "tapes_stop": "stop", "tapes_list": "takes",
    ]

    // MARK: Boucle JSON-RPC

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }

    private func reply(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func fail(_ id: Any, code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        guard let id = message["id"] else { return }              // notification : pas de réponse
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let version = params?["protocolVersion"] as? String ?? "2025-03-26"
            reply(id, result: ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                               "serverInfo": ["name": "mtapes", "version": "0.2.0"], "instructions": Self.instructions])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": tools()])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let controlMethod = Self.methodForTool[name] else { fail(id, code: -32602, "Unknown tool: \(name)"); return }
            let (text, isError) = callApp(method: controlMethod, arguments: arguments)
            reply(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            fail(id, code: -32601, "Method not found: \(method)")
        }
    }

    // MARK: Appel de l'appli

    private func callApp(method: String, arguments: [String: Any]) -> (String, Bool) {
        if let problem = ensureApp() { return (problem, true) }
        do {
            let params = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let response = try ControlClient.call(path: socketPath, method: method, params: params, timeout: 90)
            if response.ok {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let text = (try? encoder.encode(response.result ?? .null)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return (text, false)
            }
            return (response.error ?? "mTAPES returned an error.", true)
        } catch {
            return ("Could not talk to mTAPES: \(error)", true)
        }
    }

    /// Lance l'appli en arrière-plan (sans fenêtre ni focus) si son socket n'existe pas encore.
    private func ensureApp() -> String? {
        if ControlClient.isReachable(path: socketPath) { return nil }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleID]
        open.standardError = Pipe(); open.standardOutput = Pipe()
        try? open.run(); open.waitUntilExit()
        for _ in 0..<16 {
            if ControlClient.isReachable(path: socketPath) { return nil }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return "mTAPES is not reachable. Make sure the app is installed, then open its menu-bar icon and tick \"AI control\" (Pilotage par IA): it is off by default so that no other program can start a recording without the user's consent."
    }
}
