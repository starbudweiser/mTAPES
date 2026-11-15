// mTAPES — enregistreur d'écran macOS : barre de menus + fenêtre du mode Simple.
// Essais sans fenêtre : --selftest (prise de 3 s), --render CHEMIN.png [--state idle|recording|done|failed|perm] [--scheme dark|light] [--lang fr|en|es|it].
import AppKit
import SwiftUI

@main
struct MTapesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("mTAPES", id: "main") {
            SimpleView(model: model)
                .task { await model.refreshWindows() }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--show") ? .presented : .suppressed)

        MenuBarExtra {
            Button(model.phase == .recording ? L.t("menu.stop") : L.t("menu.record")) { model.toggle() }
                .disabled(model.phase == .finishing)
            Button(L.t("menu.open")) { openWindow(id: "main"); NSApp.activate() }
            Divider()
            Button(L.t("menu.about")) { About.show() }
            Button(L.t("menu.quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Cassette.menuBarImage())
            if model.phase == .recording {
                Text(AppModel.clock(model.elapsed)).monospacedDigit().foregroundStyle(.red)
            }
        }
    }
}

/// Silhouette de cassette (icône de la barre de menus en couleur, sans carré de fond), dessinée en code.
enum Cassette {
    static let rose = NSColor(srgbRed: 0xf4 / 255, green: 0x3f / 255, blue: 0x5e / 255, alpha: 1)

    static func menuBarImage() -> NSImage {
        NSImage(size: NSSize(width: 22, height: 14), flipped: false) { rect in
            draw(in: rect, color: rose)
            return true
        }
    }

    /// Dessine le motif dans `rect` (rapport 64 × 40) : corps, fenêtre évidée, deux bobines, bas évidé.
    static func draw(in rect: NSRect, color: NSColor) {
        let s = min(rect.width / 64, rect.height / 40)
        let w = 64 * s, h = 40 * s
        let ox = rect.midX - w / 2, oy = rect.midY - h / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (40 - y) * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: ox + x * s, y: oy + (40 - y - h) * s, width: w * s, height: h * s) }
        guard let ctx = NSGraphicsContext.current else { return }
        color.setFill()
        NSBezierPath(roundedRect: r(1, 1, 62, 38), xRadius: 5 * s, yRadius: 5 * s).fill()
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear
        NSBezierPath(roundedRect: r(9, 8, 46, 16), xRadius: 3 * s, yRadius: 3 * s).fill()
        let base = NSBezierPath()
        base.move(to: p(16, 39)); base.line(to: p(20, 30)); base.line(to: p(44, 30)); base.line(to: p(48, 39)); base.close()
        base.fill()
        ctx.restoreGraphicsState()
        color.setFill()
        NSBezierPath(ovalIn: r(16, 11, 10, 10)).fill()
        NSBezierPath(ovalIn: r(38, 11, 10, 10)).fill()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--lang"), i + 1 < args.count { L.override = args[i + 1] }
        Socle.brand("mTAPES", color: Color(nsColor: About.brandColor))
        Socle.apply()
        if args.contains("--selftest") {
            Task { await AppModel.shared.selftest(); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            render(to: args[i + 1], args: args)
            return
        }
        // ⌥⌘R : touche R (code 15), modificateurs Commande (256) + Option (2048).
        HotKey.register(keyCode: 15, modifiers: 256 | 2048) {
            Task { @MainActor in AppModel.shared.toggle() }
        }
    }

    private func render(to path: String, args: [String]) {
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let model = AppModel()
        switch opt("--state") ?? "idle" {
        case "recording": model.phase = .recording; model.elapsed = 42
        case "done":
            model.phase = .done(.init(url: URL(fileURLWithPath: NSHomeDirectory() + "/Movies/mTAPES/Prise 2026-11-15 10.42.00.tape"), seconds: 72, bytes: 14_300_000, frames: 1860, dropped: 0))
        case "failed": model.phase = .failed(EngineError.screenRecordingDenied.description)
        case "perm": model.screenAllowed = false
        default: break
        }
        if opt("--kind") == "window" { model.kind = .window }
        let scheme = opt("--scheme") ?? "dark"
        Socle.apply(scheme == "light" ? .light : .dark)
        let view = SimpleView(model: model)
            .environment(\.colorScheme, scheme == "light" ? .light : .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("RENDER OK \(path)")
        } else {
            print("RENDER ÉCHEC")
        }
        exit(0)
    }
}
