import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Ce qu'on peut filmer : écran, fenêtre (même masquée), application entière, ou zone d'un écran.
public enum CaptureTarget {
    case display(index: Int?)                              // 1 = premier écran ; nil = écran principal
    case window(id: UInt32)
    case app(bundleID: String, displayIndex: Int?)
    case zone(displayIndex: Int?, rect: CGRect)            // rect en points, repère de l'écran, origine en haut à gauche
}

public struct TargetInfo: Codable {
    public var kind: String            // display | window | app
    public var id: UInt32
    public var title: String
    public var app: String?
    public var bundle: String?
    public var bounds: [Double]
    public var onScreen: Bool
}

struct ResolvedTarget {
    var filter: SCContentFilter
    var sourceRect: CGRect?
    var pixelWidth: Int
    var pixelHeight: Int
    var source: TapeMeta.Source
}

public enum TargetCatalog {
    public static func content() async throws -> SCShareableContent {
        _ = CGMainDisplayID()      // initialise CoreGraphics dans un programme sans interface (sinon CGS_REQUIRE_INIT)
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !Permissions.screenRecording { throw EngineError.screenRecordingDenied }
            throw error
        }
    }

    public static func list() async throws -> [TargetInfo] {
        let content = try await content()
        var out: [TargetInfo] = []
        for d in content.displays {
            out.append(TargetInfo(kind: "display", id: d.displayID, title: "Écran \(d.displayID) · \(Int(d.width)) × \(Int(d.height)) pt",
                                  app: nil, bundle: nil,
                                  bounds: [d.frame.origin.x, d.frame.origin.y, d.frame.width, d.frame.height], onScreen: true))
        }
        for w in content.windows where w.windowLayer == 0 && w.frame.width > 40 && w.frame.height > 40 {
            out.append(TargetInfo(kind: "window", id: w.windowID, title: w.title ?? "",
                                  app: w.owningApplication?.applicationName, bundle: w.owningApplication?.bundleIdentifier,
                                  bounds: [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height], onScreen: w.isOnScreen))
        }
        var seen = Set<String>()
        for a in content.applications where !a.bundleIdentifier.isEmpty && seen.insert(a.bundleIdentifier).inserted {
            out.append(TargetInfo(kind: "app", id: UInt32(a.processID), title: a.applicationName, app: a.applicationName,
                                  bundle: a.bundleIdentifier, bounds: [], onScreen: true))
        }
        return out
    }

    static func display(_ index: Int?, in content: SCShareableContent) throws -> SCDisplay {
        if let i = index {
            guard i >= 1, i <= content.displays.count else { throw EngineError.targetNotFound("écran \(i)") }
            return content.displays[i - 1]
        }
        let main = CGMainDisplayID()
        guard let d = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
            throw EngineError.targetNotFound("écran principal")
        }
        return d
    }

    static func resolve(_ target: CaptureTarget, content: SCShareableContent, excludeOwnApp: Bool) throws -> ResolvedTarget {
        let ownBundle = Bundle.main.bundleIdentifier
        let excluded = excludeOwnApp ? content.applications.filter { $0.bundleIdentifier == ownBundle && ownBundle != nil } : []

        switch target {
        case .display(let index):
            let d = try display(index, in: content)
            let filter = SCContentFilter(display: d, excludingApplications: excluded, exceptingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            return ResolvedTarget(
                filter: filter, sourceRect: nil,
                pixelWidth: Geometry.evenPixels(info.contentRect.width * CGFloat(scale)),
                pixelHeight: Geometry.evenPixels(info.contentRect.height * CGFloat(scale)),
                source: .init(kind: "display", displayID: d.displayID,
                              bounds: [d.frame.origin.x, d.frame.origin.y, d.frame.width, d.frame.height], scale: scale))

        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else {
                throw EngineError.targetNotFound("fenêtre \(id)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            return ResolvedTarget(
                filter: filter, sourceRect: nil,
                pixelWidth: Geometry.evenPixels(info.contentRect.width * CGFloat(scale)),
                pixelHeight: Geometry.evenPixels(info.contentRect.height * CGFloat(scale)),
                source: .init(kind: "window", windowID: id, windowTitle: w.title, appBundle: w.owningApplication?.bundleIdentifier,
                              bounds: [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height], scale: scale))

        case .app(let bundle, let index):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundle }) else {
                throw EngineError.targetNotFound("application \(bundle)")
            }
            let d = try display(index, in: content)
            let filter = SCContentFilter(display: d, including: [app], exceptingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            return ResolvedTarget(
                filter: filter, sourceRect: nil,
                pixelWidth: Geometry.evenPixels(info.contentRect.width * CGFloat(scale)),
                pixelHeight: Geometry.evenPixels(info.contentRect.height * CGFloat(scale)),
                source: .init(kind: "app", displayID: d.displayID, appBundle: bundle,
                              bounds: [d.frame.origin.x, d.frame.origin.y, d.frame.width, d.frame.height], scale: scale))

        case .zone(let index, let rect):
            let d = try display(index, in: content)
            let filter = SCContentFilter(display: d, excludingApplications: excluded, exceptingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            return ResolvedTarget(
                filter: filter, sourceRect: rect,
                pixelWidth: Geometry.evenPixels(rect.width * CGFloat(scale)),
                pixelHeight: Geometry.evenPixels(rect.height * CGFloat(scale)),
                source: .init(kind: "zone", displayID: d.displayID,
                              bounds: [d.frame.origin.x + rect.origin.x, d.frame.origin.y + rect.origin.y, rect.width, rect.height],
                              scale: scale))
        }
    }
}
