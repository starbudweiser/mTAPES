import Foundation

// Cœur du serveur MCP, indépendant du transport : JSON-RPC 2.0 -> réponse. Le transport (stdio dans `mtapes-cli mcp`, HTTP local dans l'appli)
// fournit le « backend » qui exécute les commandes liées à l'écran (démarrer, marquer, arrêter…) dans l'appli qui détient l'autorisation d'écran.
// La finition et l'export se font dans le processus du transport : ils n'ont pas besoin de cette autorisation.

public struct MCPCore: Sendable {
    public typealias Backend = @Sendable (_ method: String, _ params: JSONValue?) async -> ControlResponse
    let backend: Backend
    public init(backend: @escaping Backend) { self.backend = backend }

    public static let instructions = """
    mTAPES records the user's screen silently and produces a raw take (.tape). Typical flow: tapes_list_targets (optional) -> tapes_start -> \
    do the work, calling tapes_mark right after EACH action you perform (click, type, scroll, key) with its screen position and a short human label, \
    and tapes_mark kind=chapter at the start of each phase -> tapes_stop. Marks become the editing script: zooms and captions follow them, so label them well \
    (e.g. "Choose a folder", not "click"). Coordinates are in points; use space=window for positions relative to the filmed window's top-left corner. \
    After tapes_stop, for the best result edit it yourself: tapes_summary -> tapes_apply_plan (see prompt edit_demo). Or quickly: tapes_finish (plans zooms on your marked actions, speeds up dead time, captions from your labels; optional) -> tapes_export with destination readme (light GIF for a README), release (1080p MP4) or short (vertical 9:16 MP4). \
    If the Mac sleeps or the screen locks, mTAPES stops and saves the take by itself: tapes_status and tapes_stop then report stopped_by and the take path. Never leave a take running: always call tapes_stop (a take also stops by itself after max_seconds, default 600). One take at a time.
    """

    public func tools() -> [[String: Any]] {
        func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        return [
            ["name": "tapes_list_targets",
             "description": "List what can be filmed: displays (index, size), open windows (window_id, app, title, bounds), running applications, and the microphones (id, name, default) for tapes_start mic_device. Use the window_id with tapes_start target=window.",
             "inputSchema": schema(["kind": ["type": "string", "enum": ["display", "window", "app", "microphone"], "description": "Only this kind (default: all). microphone lists the microphones usable with tapes_start audio=mic."]])],
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
                "audio": ["type": "string", "enum": ["none", "system", "mic", "both"], "description": "Record sound as separate tracks: system = the Mac's sound (not mTAPES), mic = the microphone (the user may be asked to allow it), both. Default none. Sound is kept in exports at normal speed only."],
                "mic_device": ["type": "string", "description": "Microphone name or id from tapes_list_targets kind=microphone (with audio=mic or both). Default: the system default microphone."],
                "color": ["type": "string", "enum": ["srgb", "p3"], "description": "Colour space of the take: srgb (default, right everywhere: web, README, GIF) or p3 (Display P3, more vivid on wide-gamut screens, Safari, QuickTime; GIF stays sRGB). HDR screens are filmed in SDR."],
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
            ["name": "tapes_finish",
             "description": "Plan the automatic editing of a finished take: zooms on the actions you marked, dead time sped up, captions from your labels. Writes finition.json inside the take and returns the plan. Optional: tapes_export plans by itself when no plan exists.",
             "inputSchema": schema([
                "tape_path": ["type": "string", "description": "Path returned by tapes_stop or tapes_list."],
                "preset": ["type": "string", "enum": ["readme", "release", "short"], "description": "Target look (default release)."],
                "ratio": ["type": "string", "enum": ["16:9", "9:16"], "description": "Force the aspect ratio."],
             ], required: ["tape_path"])],
            ["name": "tapes_summary",
             "description": "Read a finished take to edit it: duration, every mark (time, kind, position 0-1, label), and the current plan. Optional frames (1-6) returns that many small screenshots spread over the take, or at the times listed in frame_times, so you can see the screen. Use it before tapes_apply_plan.",
             "inputSchema": schema([
                "tape_path": ["type": "string"],
                "frames": ["type": "integer", "description": "Number of screenshots to return (0-6, default 0)."],
                "frame_times": ["type": "array", "items": ["type": "number"], "description": "Instants (seconds of the raw take) to screenshot, up to 6."],
             ], required: ["tape_path"])],
            ["name": "tapes_apply_plan",
             "description": "Apply YOUR editing decisions to a take (AI auto-edit). Times are seconds of the RAW take; positions x, y are 0-1 across the image. Sections you omit keep the current plan (or the automatic one). Everything is validated and clamped; read the returned warnings. Call tapes_export afterwards. Guide: prompt edit_demo.",
             "inputSchema": schema([
                "tape_path": ["type": "string"],
                "preset": ["type": "string", "enum": ["readme", "release", "short"], "description": "Target look; changing it recomputes the base plan."],
                "zooms": ["type": "array", "description": "Zoom plateaus.", "items": ["type": "object", "properties": ["from_s": ["type": "number"], "to_s": ["type": "number"], "scale": ["type": "number", "description": "1.1-3, usually 1.6-2.2"], "x": ["type": "number"], "y": ["type": "number"]], "required": ["from_s", "to_s", "x", "y"]]],
                "speeds": ["type": "array", "description": "Ranges played faster (dead time).", "items": ["type": "object", "properties": ["from_s": ["type": "number"], "to_s": ["type": "number"], "factor": ["type": "number", "description": "0.25-16, usually 3-8"]], "required": ["from_s", "to_s", "factor"]]],
                "captions": ["type": "array", "description": "Short text pills.", "items": ["type": "object", "properties": ["from_s": ["type": "number"], "to_s": ["type": "number"], "text": ["type": "string"]], "required": ["from_s", "to_s", "text"]]],
                "cursor": ["type": "object", "properties": ["show": ["type": "boolean"], "ripple": ["type": "boolean"], "size_percent": ["type": "number"]]],
             ], required: ["tape_path"])],
            ["name": "tapes_export",
             "description": "Render the finished demo. destination: readme = light GIF (about 960 px, under 9.5 MB) for a README; release = 1920x1080 MP4 for a GitHub release; short = vertical 1080x1920 MP4 for social networks. Takes about the length of the video to render; returns the file path, size and duration.",
             "inputSchema": schema([
                "tape_path": ["type": "string"],
                "destination": ["type": "string", "enum": ["readme", "release", "short"]],
                "target_megabytes": ["type": "number", "description": "Aim for this file size (default 9.5 for readme, automatic otherwise)."],
             ], required: ["tape_path", "destination"])],
            ["name": "tapes_list",
             "description": "List recent takes in ~/Movies/mTAPES (newest first) with name, duration, size, origin and state.",
             "inputSchema": schema(["limit": ["type": "integer", "description": "Maximum number of takes (default 10)."]])],
        ]
    }

    static let methodForTool: [String: String] = [
        "tapes_list_targets": "targets", "tapes_start": "start", "tapes_mark": "mark",
        "tapes_status": "status", "tapes_stop": "stop", "tapes_list": "takes",
    ]


    // MARK: JSON-RPC

    /// Traite un message ; renvoie la réponse, ou nil pour une notification. `clientName` est lu à l'initialisation puis transmis à chaque commande.
    public func handle(_ message: [String: Any], clientName: inout String) async -> [String: Any]? {
        guard let method = message["method"] as? String, let id = message["id"] else { return nil }
        func reply(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ text: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]] }
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let version = params?["protocolVersion"] as? String ?? "2025-03-26"
            if let info = params?["clientInfo"] as? [String: Any], let n = info["name"] as? String, !n.isEmpty { clientName = n }
            return reply(["protocolVersion": version, "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
                          "serverInfo": ["name": "mtapes", "version": "0.8.0"], "instructions": Self.instructions])
        case "ping":
            return reply([:])
        case "prompts/list":
            return reply(["prompts": [["name": "edit_demo", "description": "Step-by-step guide to edit a recorded demo (zooms, dead time, captions) with tapes_summary and tapes_apply_plan.",
                                      "arguments": [["name": "tape_path", "description": "Path of the take to edit.", "required": false]]]]])
        case "prompts/get":
            let params = message["params"] as? [String: Any] ?? [:]
            guard params["name"] as? String == "edit_demo" else { return fail(-32602, "Unknown prompt") }
            let path = (params["arguments"] as? [String: Any])?["tape_path"] as? String
            let text = Montage.guide + (path.map { "\nTake to edit: \($0)" } ?? "")
            return reply(["description": "Edit a demo with mTAPES", "messages": [["role": "user", "content": ["type": "text", "text": text]]]])
        case "tools/list":
            return reply(["tools": tools()])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            var arguments = params["arguments"] as? [String: Any] ?? [:]
            arguments["mcp_client"] = clientName
            let (text, isError): (String, Bool)
            if ["tapes_finish", "tapes_export", "tapes_summary", "tapes_apply_plan"].contains(name) {
                let (t, e, images) = await callLocal(name: name, arguments: arguments, clientName: clientName)
                var content: [[String: Any]] = [["type": "text", "text": t]]
                content.append(contentsOf: images)
                return reply(["content": content, "isError": e])
            } else if let controlMethod = Self.methodForTool[name] {
                (text, isError) = await callApp(method: controlMethod, arguments: arguments)
            } else {
                return fail(-32602, "Unknown tool: \(name)")
            }
            return reply(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }

    private func callApp(method: String, arguments: [String: Any]) async -> (String, Bool) {
        let params = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let response = await backend(method, params)
        if response.ok {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return ((try? encoder.encode(response.result ?? .null)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}", false)
        }
        return (response.error ?? "mTAPES returned an error.", true)
    }

    // MARK: Finition et export (dans ce processus)

    private func callLocal(name: String, arguments: [String: Any], clientName: String) async -> (String, Bool, [[String: Any]]) {
        let (authText, authError) = await callApp(method: "authorize", arguments: ["mcp_client": clientName])
        if authError { return (authText, true, []) }
        guard let path = arguments["tape_path"] as? String else { return ("tape_path is required.", true, []) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/mTAPES").standardizedFileURL.path
        guard url.pathExtension == "tape", url.path.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: url.appendingPathComponent("meta.json").path) else {
            return ("tape_path must be a .tape folder inside ~/Movies/mTAPES (use the path returned by tapes_stop or tapes_list).", true, [])
        }
        let package = TapePackage(url: url)
        func json(_ object: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        do {
            if name == "tapes_finish" {
                let preset = FinishingPreset(rawValue: arguments["preset"] as? String ?? "release") ?? .release
                let spec = try Finisher.plan(package, preset: preset, ratio: arguments["ratio"] as? String)
                try Finisher.save(spec, to: package)
                func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
                return (json(["finition_path": package.finishingURL.path, "preset": spec.preset, "canvas": "\(spec.canvas.width)x\(spec.canvas.height)",
                              "zooms": spec.zooms.map { ["from_s": r($0.t0), "to_s": r($0.t1), "scale": r($0.scale)] },
                              "sped_up": spec.speeds.map { ["from_s": r($0.t0), "to_s": r($0.t1), "factor": $0.factor] },
                              "captions": spec.captions.map { $0.text }]), false, [])
            }
            if name == "tapes_summary" {
                var out = try Montage.summary(package)
                var images: [[String: Any]] = []
                let times = (arguments["frame_times"] as? [NSNumber])?.map(\.doubleValue)
                let count = (arguments["frames"] as? NSNumber)?.intValue ?? 0
                if count > 0 || times?.isEmpty == false {
                    let shots = try await Montage.frames(package, count: count, times: times)
                    out["frames"] = shots.map { ["t": Montage.r2($0.t)] }
                    images = shots.map { ["type": "image", "data": $0.jpeg.base64EncodedString(), "mimeType": "image/jpeg"] }
                }
                return (json(out), false, images)
            }
            if name == "tapes_apply_plan" {
                let preset = FinishingPreset(rawValue: arguments["preset"] as? String ?? "release") ?? .release
                let (spec, warnings) = try Montage.apply(package, preset: preset, ratio: arguments["ratio"] as? String, arguments: arguments)
                var out = Montage.describe(spec, duration: try package.readMeta().durationSeconds)
                out["warnings"] = warnings
                return (json(out), false, [])
            }
            guard let dest = Destination(rawValue: arguments["destination"] as? String ?? "") else { return ("destination must be readme, release or short.", true, []) }
            let target = (arguments["target_megabytes"] as? NSNumber)?.doubleValue
            let result = try await Exporter.export(package, destination: dest, targetMegabytes: target)
            return (json(["path": result.path, "format": result.format, "size": "\(result.width)x\(result.height)", "duration_s": result.durationSeconds,
                          "megabytes": result.megabytes, "render_s": result.renderSeconds, "queued_s": result.queuedSeconds]), false, [])
        } catch {
            return ("\(name) failed: \(error)", true, [])
        }
    }
}
