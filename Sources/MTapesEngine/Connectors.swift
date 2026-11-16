import Foundation

// Raccordement en un clic des clients MCP : écrit l'entrée « mtapes » dans leur configuration (sauvegarde d'abord), ou appelle leur commande officielle.

public struct MCPClientInfo: Identifiable, Equatable {
    public enum Status: Equatable { case notDetected, detected, connected }
    public var id: String
    public var name: String
    public var status: Status
}

public enum Connectors {
    enum Kind { case claudeCode, json(String), toml(String) }

    static func clients(home: URL) -> [(id: String, name: String, kind: Kind, detect: [String])] {
        func h(_ p: String) -> String { home.appendingPathComponent(p).path }
        return [
            ("claude-code", "Claude Code", .claudeCode, [h(".claude.json"), h(".local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]),
            ("claude-desktop", "Claude Desktop", .json(h("Library/Application Support/Claude/claude_desktop_config.json")), [h("Library/Application Support/Claude"), "/Applications/Claude.app"]),
            ("cursor", "Cursor", .json(h(".cursor/mcp.json")), [h(".cursor"), "/Applications/Cursor.app"]),
            ("codex", "Codex", .toml(h(".codex/config.toml")), [h(".codex")]),
            ("gemini", "Gemini CLI", .json(h(".gemini/settings.json")), [h(".gemini")]),
        ]
    }

    public static func list(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [MCPClientInfo] {
        clients(home: home).map { c in
            let detected = c.detect.contains { FileManager.default.fileExists(atPath: $0) }
            return MCPClientInfo(id: c.id, name: c.name, status: !detected ? .notDetected : (isConnected(c.kind, home: home) ? .connected : .detected))
        }
    }

    static func isConnected(_ kind: Kind, home: URL) -> Bool {
        switch kind {
        case .claudeCode:
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude.json")))) as? [String: Any]
            return ((json?["mcpServers"] as? [String: Any])?["mtapes"]) != nil
        case .json(let path):
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any]
            return ((json?["mcpServers"] as? [String: Any])?["mtapes"]) != nil
        case .toml(let path):
            return ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains("[mcp_servers.mtapes]")
        }
    }

    /// Raccorde un client. `cli` : chemin de `mtapes-cli` dans le paquet de l'appli.
    public static func connect(id: String, cli: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let c = clients(home: home).first(where: { $0.id == id }) else { throw EngineError.targetNotFound(id) }
        switch c.kind {
        case .claudeCode:
            guard let claude = ["\(home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw EngineError.writerFailed("commande claude introuvable")
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["mcp", "add", "--scope", "user", "mtapes", "--", cli, "mcp"]
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw EngineError.writerFailed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        case .json(let path):
            try mergeJSON(path: path, cli: cli)
        case .toml(let path):
            var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            guard !text.contains("[mcp_servers.mtapes]") else { return }
            try backup(path)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n[mcp_servers.mtapes]\ncommand = \"\(cli)\"\nargs = [\"mcp\"]\n"
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func backup(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let b = path + ".mtapes-backup"
        if !FileManager.default.fileExists(atPath: b) { try FileManager.default.copyItem(atPath: path, toPath: b) }
    }

    static func mergeJSON(path: String, cli: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw EngineError.writerFailed("configuration illisible : \(path)") }
            root = parsed
        }
        try backup(path)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["mtapes"] = ["command": cli, "args": ["mcp"]]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
