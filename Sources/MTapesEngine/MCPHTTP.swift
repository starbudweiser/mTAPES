import Foundation
import Network
import Security

// Transport HTTP local du serveur MCP, pour les clients qui ne savent pas lancer une commande : POST http://127.0.0.1:PORT/mcp,
// jeton obligatoire (en-tête Authorization: Bearer …), limité à cet ordinateur (adresse de bouclage, en-tête Host vérifié contre le « DNS rebinding »).

public enum MCPHTTPPaths {
    public static func port(dev: Bool) -> UInt16 { dev ? 47322 : 47321 }

    public static func tokenPath(dev: Bool) -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dev ? "mTAPES-dev" : "mTAPES")")
        return base.appendingPathComponent("http.token").path
    }

    /// Jeton aléatoire (256 bits), créé à la première utilisation, droits 600.
    public static func loadOrCreateToken(dev: Bool) throws -> String {
        let path = tokenPath(dev: dev)
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing.count >= 32 { return existing.trimmingCharacters(in: .whitespacesAndNewlines) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw EngineError.writerFailed("jeton impossible") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try token.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o600)
        return token
    }
}

public final class MCPHTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let token: String
    private let core: MCPCore
    private var listener: NWListener?
    private var sessions: [String: String] = [:]          // identifiant de session -> nom du client
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mtapes.http")

    public init(port: UInt16, token: String, core: MCPCore) { self.port = port; self.token = token; self.core = core }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 4_000_000 { self.respond(connection, status: 413, body: nil); return }
            if let request = HTTPRequest.parse(buffer) {
                Task { await self.handle(request, on: connection) }
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        let hostOK = request.header("host").map { ["127.0.0.1:\(port)", "localhost:\(port)"].contains($0.lowercased()) } ?? false
        guard hostOK else { respond(connection, status: 403, body: nil); return }
        guard request.path == "/mcp" else { respond(connection, status: 404, body: nil); return }
        guard request.header("authorization") == "Bearer \(token)" else { respond(connection, status: 401, body: nil); return }
        guard request.method == "POST" else { respond(connection, status: 405, body: nil); return }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else { respond(connection, status: 400, body: nil); return }

        var session = request.header("mcp-session-id")
        lock.lock()
        var client = session.flatMap { sessions[$0] } ?? "unknown"
        lock.unlock()
        let isInitialize = (object["method"] as? String) == "initialize"
        let reply = await core.handle(object, clientName: &client)
        var headers: [String: String] = [:]
        if isInitialize {
            let id = UUID().uuidString.lowercased()
            lock.lock(); sessions[id] = client; lock.unlock()
            session = id
            headers["Mcp-Session-Id"] = id
        }
        guard let reply, let body = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) else {
            respond(connection, status: 202, body: nil, headers: headers); return
        }
        respond(connection, status: 200, body: body, headers: headers)
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data?, headers: [String: String] = [:]) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Renvoie la requête quand elle est complète (en-têtes + corps annoncé par Content-Length), sinon nil.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        lines.removeFirst()
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[l.startIndex..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}
