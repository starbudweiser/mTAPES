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
