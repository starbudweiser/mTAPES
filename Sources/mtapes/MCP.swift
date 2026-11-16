#if canImport(MTapesEngine)
import MTapesEngine
#endif
import Foundation

// `mtapes mcp` : transport stdio du serveur MCP. Il ne filme rien : les commandes liées à l'écran sont transmises à l'appli mTAPES par un socket
// Unix privé (l'appli détient l'autorisation d'écran) ; elle est lancée en arrière-plan si besoin.

struct MCPServer {
    let dev: Bool
    var bundleID: String { dev ? "fr.stephan.mtapes.dev" : "fr.stephan.mtapes" }
    var socketPath: String { ControlPaths.socketPath(dev: dev) }

    func run() {
        let backend: MCPCore.Backend = { method, params in
            if let problem = ensureApp() { return .failure(1, problem) }
            do { return try ControlClient.call(path: socketPath, method: method, params: params, timeout: 90) }
            catch { return .failure(1, "Could not talk to mTAPES: \(error)") }
        }
        let core = MCPCore(backend: backend)
        var clientName = "unknown"
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let box = ReplyBox()
            let done = DispatchSemaphore(value: 0)
            let name = clientName
            Task { var n = name; box.reply = await core.handle(object, clientName: &n); box.client = n; done.signal() }
            done.wait()
            clientName = box.client
            guard let reply = box.reply,
                  let out = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]),
                  let text = String(data: out, encoding: .utf8) else { continue }
            print(text); fflush(stdout)
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

private final class ReplyBox: @unchecked Sendable { var reply: [String: Any]?; var client = "unknown" }
