import Darwin
import Foundation

// Canal de pilotage entre l'appli (qui détient l'autorisation d'enregistrer l'écran) et les programmes qui la commandent
// (serveur MCP `mtapes mcp`, essais). Socket Unix privé, une requête JSON par ligne, une réponse JSON par ligne.

/// Valeur JSON quelconque (paramètres et résultats des requêtes).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSON invalide") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}

public struct ControlRequest: Codable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue?
    public init(id: Int, method: String, params: JSONValue? = nil) { self.id = id; self.method = method; self.params = params }
}

public struct ControlResponse: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?
    public init(id: Int, ok: Bool, result: JSONValue? = nil, error: String? = nil) { self.id = id; self.ok = ok; self.result = result; self.error = error }
    public static func failure(_ id: Int, _ message: String) -> ControlResponse { .init(id: id, ok: false, error: message) }
}

public enum ControlPaths {
    /// Dossier propre à chaque édition : l'appli installée et l'appli de développement ont chacune leur socket.
    public static func socketPath(dev: Bool) -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dev ? "mTAPES-dev" : "mTAPES")")
        return base.appendingPathComponent("mcp.sock").path
    }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= capacity else { throw EngineError.writerFailed("chemin de socket trop long") }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            for (i, c) in bytes.enumerated() { dst[i] = c }
        }
    }
    return addr
}

/// Serveur : écoute sur un socket Unix (droits 600, dossier 700, uniquement le même utilisateur) et passe chaque requête à `handler`.
public final class ControlServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (ControlRequest) async -> ControlResponse
    private var listenFD: Int32 = -1
    private let lock = NSLock()

    public init(path: String, handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.writerFailed("socket impossible (\(errno))") }
        var addr = try makeAddress(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { close(fd); throw EngineError.writerFailed("bind impossible (\(errno))") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw EngineError.writerFailed("listen impossible (\(errno))") }
        lock.lock(); listenFD = fd; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { return }
            pending.append(contentsOf: chunk[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                guard !line.isEmpty else { continue }
                let response: ControlResponse
                if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                    let box = ResponseBox()
                    let done = DispatchSemaphore(value: 0)
                    let handler = self.handler
                    Task { box.value = await handler(request); done.signal() }
                    done.wait()
                    response = box.value ?? .failure(request.id, "pas de réponse")
                } else {
                    response = .failure(0, "requête illisible")
                }
                var out = (try? JSONEncoder().encode(response)) ?? Data()
                out.append(0x0A)
                var sent = 0
                out.withUnsafeBytes { raw in
                    while sent < out.count {
                        let w = send(client, raw.baseAddress!.advanced(by: sent), out.count - sent, 0)
                        if w <= 0 { return }
                        sent += w
                    }
                }
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable { var value: ControlResponse? }

/// Client : une connexion par appel (simple et robuste), avec délai de réponse.
public enum ControlClient {
    public static func isReachable(path: String) -> Bool {
        guard let fd = try? connectSocket(path) else { return false }
        close(fd)
        return true
    }

    public static func call(path: String, method: String, params: JSONValue? = nil, id: Int = 1, timeout: TimeInterval = 120) throws -> ControlResponse {
        let fd = try connectSocket(path)
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = try JSONEncoder().encode(ControlRequest(id: id, method: method, params: params))
        data.append(0x0A)
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < data.count {
                let w = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if w <= 0 { throw EngineError.writerFailed("envoi impossible (\(errno))") }
                sent += w
            }
        }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !pending.contains(0x0A) {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { throw EngineError.writerFailed("pas de réponse de l'appli (délai ou connexion fermée)") }
            pending.append(contentsOf: chunk[0..<n])
        }
        let line = pending.prefix { $0 != 0x0A }
        return try JSONDecoder().decode(ControlResponse.self, from: Data(line))
    }

    private static func connectSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.writerFailed("socket impossible (\(errno))") }
        var addr = try makeAddress(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        guard ok == 0 else { close(fd); throw EngineError.writerFailed("connexion impossible (\(errno))") }
        return fd
    }
}
