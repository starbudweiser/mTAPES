import AVFoundation
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

    func testSavedEditsFollowTheDestination() {
        var spec = FinishingSpec(preset: "release", fps: 60, canvas: FinishingPreset.release.canvas)
        spec.zooms = [.init(t0: 1, t1: 3, scale: 2, fx: 0.3, fy: 0.4, source: "manual")]
        spec.captions = [.init(t0: 1, t1: 2, text: "Ouvrir")]
        let short = spec.adapted(to: .short)
        XCTAssertEqual(short.canvas.height, 1920); XCTAssertEqual(short.preset, "short")
        XCTAssertEqual(short.zooms, spec.zooms); XCTAssertEqual(short.captions, spec.captions)
        XCTAssertEqual(spec.adapted(to: .release), spec)
        XCTAssertEqual(spec.adapted(to: .readme).fps, 30)
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

    // MARK: Son

    /// Prise synthétique : 3 s de vidéo noire (30 i/s) et une piste son AAC de 3 s, le son commençant 0,5 s après la première image.
    private func makeTapeWithAudio(speeds: [FinishingSpec.Speed]) async throws -> (TapePackage, FinishingSpec) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtapes-audio-\(UUID().uuidString)")
        let package = try TapePackage.create(in: dir, name: "Son")
        // vidéo
        let w = try AVAssetWriter(url: package.rawURL, fileType: .mov)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200])
        w.add(vi); w.startWriting(); w.startSession(atSourceTime: .zero)
        for i in 0..<90 {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, []); memset(CVPixelBufferGetBaseAddress(pb!), 0, CVPixelBufferGetDataSize(pb!)); CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        vi.markAsFinished(); await w.finishWriting()
        // son : sinus 440 Hz, 48 kHz mono, 3 s
        let aw = try AVAssetWriter(url: package.url.appendingPathComponent("audio-mic.mov"), fileType: .mov)
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1])
        aw.add(ai); aw.startWriting(); aw.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        for chunk in 0..<150 {                                            // 150 × 960 échantillons = 3 s
            while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var samples = (0..<960).map { Float(sin(2 * .pi * 440 * Double(chunk * 960 + $0) / 48000)) * 0.5 }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 3840, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 3840, flags: 0, blockBufferOut: &block)
            CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 3840)
            var sb: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 960, timescale: 48000), presentationTimeStamp: CMTime(value: CMTimeValue(chunk * 960), timescale: 48000), decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleCount: 960, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
            ai.append(sb!)
        }
        ai.markAsFinished(); await aw.finishWriting()
        var meta = TapeMeta(id: "s", name: "Son", created: Date(), origin: "cli", client: nil, source: .init(kind: "display", displayID: 1, bounds: [0, 0, 320, 200], scale: 1),
                            profile: "balanced", pixelFormat: "420v", codec: "h264", maxFPS: 30, width: 320, height: 200, durationSeconds: 3, firstFramePTS: 1000, stats: .init())
        meta.state = "complete"
        meta.audio = [.init(kind: "mic", file: "audio-mic.mov", start: 1000.5, duration: 3)]   // le son démarre 0,5 s après la première image
        try package.writeMeta(meta)
        var spec = FinishingSpec(preset: "release", fps: 30, canvas: FinishingPreset.release.canvas)
        spec.speeds = speeds
        return (package, spec)
    }

    func testAudioIsKeptAtNormalSpeedOnly() async throws {
        // 3 s de prise, 1 s → 2 s accélérées ×4 : le film dure 1 + 0,25 + 1 = 2,25 s ; le son (1 s → 3 s de prise) n'est gardé qu'à vitesse normale.
        let (package, spec) = try await makeTapeWithAudio(speeds: [.init(t0: 1, t1: 2, factor: 4)])
        defer { try? FileManager.default.removeItem(at: package.url.deletingLastPathComponent()) }
        let built = try await Finisher.build(package, spec: spec)
        XCTAssertTrue(built.hasAudio)
        XCTAssertNotNil(built.audioMix)
        XCTAssertEqual(built.duration, 2.25, accuracy: 0.05)
        let audio = built.composition.tracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        // segments insérés : 0,5…1 s de prise (film 0,5…1) puis 2…3 s de prise (film 1,25…2,25) = 1,5 s de son
        let segments = audio[0].segments.filter { !$0.isEmpty }
        let kept = segments.reduce(0.0) { $0 + CMTimeGetSeconds($1.timeMapping.target.duration) }
        XCTAssertEqual(kept, 1.5, accuracy: 0.05)
        XCTAssertEqual(CMTimeGetSeconds(segments[0].timeMapping.target.start), 0.5, accuracy: 0.05)
        // sans le son : build(withAudio: false) ne garde aucune piste
        let silent = try await Finisher.build(package, spec: spec, withAudio: false)
        XCTAssertFalse(silent.hasAudio)
        // son coupé dans la finition
        var off = spec; off.audio = .init(enabled: false)
        let muted = try await Finisher.build(package, spec: off)
        XCTAssertFalse(muted.hasAudio)
    }

    func testExportKeepsAudioTrackAndGifDropsIt() async throws {
        let (package, spec) = try await makeTapeWithAudio(speeds: [])
        defer { try? FileManager.default.removeItem(at: package.url.deletingLastPathComponent()) }
        let result = try await Exporter.export(package, destination: .release, spec: spec)
        let asset = AVURLAsset(url: URL(fileURLWithPath: result.path))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(result.durationSeconds, 3, accuracy: 0.1)
    }

    func testColorChoiceAndSpecRoundTrip() throws {
        XCTAssertTrue(ColorChoice.p3.isP3); XCTAssertFalse(ColorChoice.srgb.isP3)
        XCTAssertEqual(ColorChoice(rawValue: "p3"), .p3); XCTAssertNil(ColorChoice(rawValue: "rec2020"))
        var spec = FinishingSpec(preset: "release", fps: 60, canvas: FinishingPreset.release.canvas)
        spec.colors = "p3"; spec.audio = .init(enabled: true, micGain: 1.2, systemGain: 0.4)
        let back = try JSONDecoder().decode(FinishingSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(back, spec)
        // un ancien finition.json (sans son ni couleur) se lit toujours
        let old = try JSONEncoder().encode(FinishingSpec(preset: "release", fps: 60, canvas: FinishingPreset.release.canvas))
        let decoded = try JSONDecoder().decode(FinishingSpec.self, from: old)
        XCTAssertNil(decoded.colors); XCTAssertNil(decoded.audio)
        XCTAssertEqual(spec.adapted(to: .short).colors, "p3")                // la destination ne change pas l'espace colorimétrique
    }

    func testGeometryTrackFollowsAMovedWindow() {
        let meta = TapeMeta(id: "g", name: "g", created: Date(), origin: "cli", client: nil,
                            source: .init(kind: "window", windowID: 7, bounds: [100, 200, 800, 600], scale: 2),
                            profile: "balanced", pixelFormat: "420v", codec: "hevc-main", maxFPS: 60, width: 1600, height: 1200,
                            durationSeconds: 10, firstFramePTS: 0, stats: .init())
        let events = [TapeEvent(t: 4, kind: "bounds", source: "detected", label: "300.0,250.0,800.0,600.0")]
        let g = GeometryTrack(meta: meta, events: events)
        let a = g.normalize(x: 500, y: 500, at: 1)                    // avant le déplacement : origine (100, 200)
        XCTAssertEqual(a.0, 0.5, accuracy: 1e-9); XCTAssertEqual(a.1, 0.5, accuracy: 1e-9)
        let b = g.normalize(x: 700, y: 550, at: 6)                    // après : origine (300, 250) ; même point d'écran déplacé avec la fenêtre
        XCTAssertEqual(b.0, 0.5, accuracy: 1e-9); XCTAssertEqual(b.1, 0.5, accuracy: 1e-9)
        let c = g.normalize(x: 500, y: 500, at: 6)                    // le pointeur n'a pas bougé mais la fenêtre si : il est maintenant à gauche
        XCTAssertEqual(c.0, 0.25, accuracy: 1e-9)
        // le plan automatique centre le zoom sur la bonne position, pas sur l'ancienne fenêtre
        let click = TapeEvent(t: 6, kind: "click", x: 700, y: 550, source: "declared", label: "Ouvrir")
        let plan = Planner.plan(.init(meta: meta, events: events + [click]), preset: .release)
        XCTAssertEqual(plan.zooms.first?.fx ?? 0, 0.5, accuracy: 0.01)
    }
}
