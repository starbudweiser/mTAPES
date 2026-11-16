import XCTest
@testable import MTapesEngine

final class EngineTests: XCTestCase {
    func testEvenPixels() {
        XCTAssertEqual(Geometry.evenPixels(1279.6), 1280)
        XCTAssertEqual(Geometry.evenPixels(1281), 1280)
        XCTAssertEqual(Geometry.evenPixels(1), 2)
    }

    func testProfilesAreOrdered() {
        XCTAssertLessThan(QualityProfile.light.videoQuality, QualityProfile.balanced.videoQuality)
        XCTAssertLessThan(QualityProfile.balanced.videoQuality, QualityProfile.max.videoQuality)
        XCTAssertEqual(QualityProfile.light.maxFPS, 30)
        XCTAssertEqual(QualityProfile.balanced.maxFPS, 60)
    }

    func testEventLogRoundTrip() throws {
        let events = [TapeEvent(t: 1.25, kind: "click", x: 10, y: 20, button: "left", source: "declared", label: "Sauvegarder"),
                      TapeEvent(t: 3, kind: "chapter", label: "Lancement")]
        XCTAssertEqual(try EventLog.decode(try EventLog.encode(events)), events)
    }

    func testPointerTrackRoundTrip() throws {
        let samples = [(t: 0.0, x: 1.5, y: 2.5), (t: 0.008, x: 3.0, y: 4.0)]
        let decoded = try XCTUnwrap(PointerTrack.decode(PointerTrack.encode(samples)))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1].x, 3.0)
        XCTAssertNil(PointerTrack.decode(Data("nope".utf8)))
    }

    func testClickDoubleClickAndDrag() {
        var d = ClickDetector()
        func tap(_ t: Double, _ x: Double = 100, _ y: Double = 100) -> [TapeEvent] {
            d.feed(.init(t: t, x: x, y: y, left: true, right: false)) + d.feed(.init(t: t + 0.05, x: x, y: y, left: false, right: false))
        }
        XCTAssertEqual(tap(1).map(\.kind), ["click"])
        XCTAssertEqual(tap(1.2).map(\.kind), ["doubleclick"])
        XCTAssertEqual(tap(3).map(\.kind), ["click"])          // trop tard pour un double-clic
        let down = d.feed(.init(t: 5, x: 0, y: 0, left: true, right: false))
        let up = d.feed(.init(t: 5.3, x: 200, y: 0, left: false, right: false))
        XCTAssertTrue(down.isEmpty)
        XCTAssertEqual(up.map(\.kind), ["drag"])
        let r1 = d.feed(.init(t: 7, x: 9, y: 9, left: false, right: true))
        let r2 = d.feed(.init(t: 7.1, x: 9, y: 9, left: false, right: false))
        XCTAssertTrue(r1.isEmpty)
        XCTAssertEqual(r2.map(\.kind), ["rightclick"])
    }

    func testPackageCreateAndMetaRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try TapePackage.create(in: dir, name: "Démo")
        let b = try TapePackage.create(in: dir, name: "Démo")
        XCTAssertEqual(a.url.lastPathComponent, "Démo.tape")
        XCTAssertEqual(b.url.lastPathComponent, "Démo 2.tape")
        let meta = TapeMeta(id: "x", name: "Démo", created: Date(timeIntervalSince1970: 1_700_000_000), origin: "cli", client: nil,
                            source: .init(kind: "display", displayID: 1, bounds: [0, 0, 1280, 800], scale: 2),
                            profile: "balanced", pixelFormat: "420v", codec: "hevc-main", maxFPS: 60, width: 2560, height: 1600,
                            durationSeconds: 12.5, firstFramePTS: 100, stats: .init())
        try a.writeMeta(meta)
        XCTAssertEqual(try a.readMeta(), meta)
    }

    func testDiskSpaceGuard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try Recorder.ensureDiskSpace(dir, minimum: 1))
        XCTAssertThrowsError(try Recorder.ensureDiskSpace(dir, minimum: Int64.max)) { error in
            guard case EngineError.diskLow = error else { return XCTFail("mauvaise erreur : \(error)") }
        }
    }

    func testMetaStateAndErrorRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try TapePackage.create(in: dir, name: "x")
        var meta = TapeMeta(id: "i", name: "x", created: Date(timeIntervalSince1970: 1_700_000_000), origin: "manual", client: nil,
                            source: .init(kind: "display", bounds: [0, 0, 10, 10], scale: 1), profile: "balanced", pixelFormat: "420v",
                            codec: "hevc-main", maxFPS: 60, width: 10, height: 10, durationSeconds: 1, firstFramePTS: 2, stats: .init())
        meta.state = "failed"; meta.error = "Flux interrompu"
        try pkg.writeMeta(meta)
        let back = try pkg.readMeta()
        XCTAssertEqual(back.state, "failed")
        XCTAssertEqual(back.error, "Flux interrompu")
    }
}

final class ControlTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object(["a": .number(1), "b": .array([.string("x"), .bool(true), .null]), "c": .object(["d": .number(2.5)])])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(value["c"]?["d"]?.double, 2.5)
        XCTAssertEqual(value["a"]?.int, 1)
    }

    func testServerAndClientLoopback() throws {
        let path = "/tmp/mtapes-test-\(getpid()).sock"
        let server = ControlServer(path: path) { request in
            if request.method == "echo" { return .init(id: request.id, ok: true, result: request.params) }
            return .failure(request.id, "inconnu")
        }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(ControlClient.isReachable(path: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let ok = try ControlClient.call(path: path, method: "echo", params: .object(["k": .string("v")]), id: 7, timeout: 5)
        XCTAssertTrue(ok.ok); XCTAssertEqual(ok.id, 7); XCTAssertEqual(ok.result?["k"]?.string, "v")
        let ko = try ControlClient.call(path: path, method: "nope", timeout: 5)
        XCTAssertFalse(ko.ok); XCTAssertEqual(ko.error, "inconnu")
        server.stop()
        XCTAssertFalse(ControlClient.isReachable(path: path))
    }
}

final class FinishingTests: XCTestCase {
    private func meta(duration: Double) -> TapeMeta {
        TapeMeta(id: "t", name: "t", created: Date(), origin: "mcp", client: nil,
                 source: .init(kind: "display", bounds: [0, 0, 1000, 500], scale: 2), profile: "balanced", pixelFormat: "420v", codec: "hevc-main",
                 maxFPS: 60, width: 2000, height: 1000, durationSeconds: duration, firstFramePTS: 0, stats: .init())
    }

    func testMontageValidatesAndClampsAIDecisions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-montage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = try TapePackage.create(in: dir, name: "m")
        try pkg.writeMeta(meta(duration: 10))
        try EventLog.encode([TapeEvent(t: 1, kind: "click", x: 500, y: 250, source: "declared", label: "Ouvrir")]).write(to: pkg.eventsURL)
        let summary = try Montage.summary(pkg)
        XCTAssertEqual((summary["events"] as? [[String: Any]])?.first?["x"] as? Double, 0.5)
        let args: [String: Any] = [
            "zooms": [["from_s": 1, "to_s": 3, "scale": 9, "x": 2, "y": -1], ["from_s": 4, "to_s": 4.1, "x": 0.5, "y": 0.5]],
            "speeds": [["from_s": 5, "to_s": 9, "factor": 4], ["from_s": 8, "to_s": 20, "factor": 100]],
            "captions": [["from_s": 1, "to_s": 3, "text": "  Ouvrir  "], ["from_s": 2, "to_s": 3, "text": ""]],
        ]
        let (spec, warnings) = try Montage.apply(pkg, preset: .release, ratio: nil, arguments: args)
        XCTAssertEqual(spec.zooms.count, 1)                                   // le zoom de 0,1 s est écarté
        XCTAssertEqual(spec.zooms[0].scale, 3)                                // borné
        XCTAssertEqual(spec.zooms[0].fx, 1); XCTAssertEqual(spec.zooms[0].fy, 0)
        XCTAssertEqual(spec.zooms[0].source, "ai")
        XCTAssertEqual(spec.speeds.count, 2)
        XCTAssertEqual(spec.speeds[1].t0, 9, accuracy: 1e-9)                  // chevauchement : le second commence où le premier finit
        XCTAssertEqual(spec.speeds[1].t1, 10, accuracy: 1e-9)                 // et reste dans la prise
        XCTAssertEqual(spec.speeds[1].factor, 16)
        XCTAssertEqual(spec.captions.map(\.text), ["Ouvrir"])
        XCTAssertGreaterThanOrEqual(warnings.count, 5)
        // Les sections absentes gardent le plan enregistré.
        let (again, _) = try Montage.apply(pkg, preset: .release, ratio: nil, arguments: ["captions": [] as [[String: Any]]])
        XCTAssertEqual(again.zooms.count, 1); XCTAssertTrue(again.captions.isEmpty)
    }

    func testTimelineMapsSourceAndOutputTime() {
        let t = FinishingSpec.Timeline(speeds: [.init(t0: 2, t1: 10, factor: 4)], sourceDuration: 12)
        XCTAssertEqual(t.outputDuration, 2 + 2 + 2, accuracy: 1e-9)           // 2 s normales, 8 s ÷ 4, 2 s normales
        XCTAssertEqual(t.sourceTime(forOutput: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(t.sourceTime(forOutput: 3), 6, accuracy: 1e-9)         // 1 s dans la partie accélérée = 4 s de source
        XCTAssertEqual(t.outputTime(forSource: 10), 4, accuracy: 1e-9)
        XCTAssertEqual(t.sourceTime(forOutput: 5), 11, accuracy: 1e-9)
    }

    func testPlannerGroupsActionsIntoZoomsAndSpeedsUpDeadTime() {
        let events = [
            TapeEvent(t: 1.0, kind: "click", x: 400, y: 100, source: "declared", label: "Ouvrir"),
            TapeEvent(t: 1.8, kind: "click", x: 450, y: 120, source: "detected"),
            TapeEvent(t: 9.0, kind: "click", x: 800, y: 400, source: "declared", label: "Valider"),
        ]
        let spec = Planner.plan(.init(meta: meta(duration: 12), events: events), preset: .release)
        XCTAssertEqual(spec.zooms.count, 2)                                   // deux groupes : 1,0-1,8 s puis 9,0 s
        XCTAssertEqual(spec.zooms[0].fx, 0.425, accuracy: 0.01)               // centre des deux premiers clics, en 0…1
        XCTAssertGreaterThanOrEqual(spec.zooms[0].scale, 1.5)
        XCTAssertLessThanOrEqual(spec.zooms[0].scale, 2.2)
        XCTAssertEqual(spec.speeds.count, 1)                                  // 1,8 → 9,0 : plus de 3 s sans action
        XCTAssertEqual(spec.captions.map(\.text), ["Ouvrir", "Valider"])      // seulement les libellés annoncés
        XCTAssertEqual(spec.canvas.width, 1920)
    }

    func testPlannerIgnoresOutOfBoundsAndUnlabelledCaptions() {
        let events = [TapeEvent(t: 1, kind: "click", x: 5000, y: 5000, source: "declared", label: "Hors écran"),
                      TapeEvent(t: 2, kind: "click", x: 10, y: 10, source: "detected")]
        let spec = Planner.plan(.init(meta: meta(duration: 5), events: events), preset: .short)
        XCTAssertEqual(spec.zooms.count, 1)                                   // le clic hors de la prise est ignoré pour le zoom
        XCTAssertEqual(spec.canvas.height, 1920)
        XCTAssertTrue(spec.canvas.fill)
    }

    func testZoomStateEasesInAndOut() {
        var spec = FinishingSpec(preset: "release", fps: 60, canvas: FinishingPreset.release.canvas)
        spec.zooms = [.init(t0: 2, t1: 4, scale: 2, fx: 0.25, fy: 0.75)]
        XCTAssertEqual(spec.zoomState(at: 0).scale, 1, accuracy: 1e-9)
        XCTAssertEqual(spec.zoomState(at: 3).scale, 2, accuracy: 1e-9)
        let mid = spec.zoomState(at: 1.775)                                   // à mi-entrée
        XCTAssertGreaterThan(mid.scale, 1.3); XCTAssertLessThan(mid.scale, 1.7)
        XCTAssertEqual(spec.zoomState(at: 3).fx, 0.25, accuracy: 1e-9)
        XCTAssertEqual(spec.zoomState(at: 10).scale, 1, accuracy: 1e-9)
    }

    func testSpecRoundTrip() throws {
        var spec = Planner.plan(.init(meta: meta(duration: 12), events: [TapeEvent(t: 1, kind: "click", x: 100, y: 100, source: "declared", label: "A")]), preset: .readme)
        spec.captions.append(.init(t0: 0, t1: 1, text: "Texte"))
        let data = try JSONEncoder().encode(spec)
        XCTAssertEqual(try JSONDecoder().decode(FinishingSpec.self, from: data), spec)
    }
}

final class ConnectorTests: XCTestCase {
    func home() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    func testJSONConnectorMergesAndBacksUp() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let dir = h.appendingPathComponent(".cursor"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = dir.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers":{"autre":{"command":"x"}},"theme":"dark"}"#.utf8).write(to: cfg)
        XCTAssertEqual(Connectors.list(home: h).first { $0.id == "cursor" }?.status, .detected)
        try Connectors.connect(id: "cursor", cli: "/Apps/mTAPES.app/Contents/MacOS/mtapes-cli", home: h)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: cfg)) as! [String: Any]
        let servers = json["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["autre"]); XCTAssertNotNil(servers["mtapes"]); XCTAssertEqual(json["theme"] as? String, "dark")   // rien d'existant n'est perdu
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.path + ".mtapes-backup"))
        XCTAssertEqual(Connectors.list(home: h).first { $0.id == "cursor" }?.status, .connected)
    }

    func testTOMLConnectorIsIdempotent() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let dir = h.appendingPathComponent(".codex"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = dir.appendingPathComponent("config.toml"); try Data("model = \"x\"".utf8).write(to: cfg)
        try Connectors.connect(id: "codex", cli: "/cli", home: h)
        try Connectors.connect(id: "codex", cli: "/cli", home: h)
        let text = try String(contentsOf: cfg, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.mtapes]").count - 1, 1)
        XCTAssertTrue(text.hasPrefix("model = \"x\""))
    }

    func testUnreadableJSONIsNotOverwritten() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let dir = h.appendingPathComponent(".gemini"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = dir.appendingPathComponent("settings.json"); try Data("pas du json".utf8).write(to: cfg)
        XCTAssertThrowsError(try Connectors.connect(id: "gemini", cli: "/cli", home: h))
        XCTAssertEqual(try String(contentsOf: cfg, encoding: .utf8), "pas du json")
    }

    func testHTTPServerAuthAndRouting() async throws {
        let core = MCPCore { method, _ in .init(id: 1, ok: true, result: .object(["phase": .string("idle")])) }
        let port: UInt16 = 47390
        let server = MCPHTTPServer(port: port, token: "secret-token-secret-token-secret-token", core: core)
        try server.start(); defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func post(_ body: String, token: String?) async throws -> (Int, Data, [AnyHashable: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            req.httpMethod = "POST"; req.httpBody = Data(body.utf8)
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let r = resp as! HTTPURLResponse
            return (r.statusCode, data, r.allHeaderFields)
        }
        let init1 = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"essai"}}}"#, token: "secret-token-secret-token-secret-token")
        XCTAssertEqual(init1.0, 200); XCTAssertNotNil(init1.2["Mcp-Session-Id"])
        let list = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, token: "secret-token-secret-token-secret-token")
        XCTAssertEqual(list.0, 200)
        let tools = ((try JSONSerialization.jsonObject(with: list.1) as! [String: Any])["result"] as! [String: Any])["tools"] as! [Any]
        XCTAssertEqual(tools.count, 10)
        let noToken = try await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: nil)
        XCTAssertEqual(noToken.0, 401)
        let badToken = try await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: "mauvais")
        XCTAssertEqual(badToken.0, 401)
        let note = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, token: "secret-token-secret-token-secret-token")
        XCTAssertEqual(note.0, 202)
    }
}
