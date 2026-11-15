// Dessine l'icône de mTAPES (carré arrondi sombre, cassette rose) : swift make_icon.swift icon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // Carré arrondi (rayon 22,7 %) à dégradé diagonal.
    let body = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: size * 0.227, yRadius: size * 0.227)
    NSGradient(starting: NSColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x42 / 255, alpha: 1),
               ending: NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x1a / 255, alpha: 1))!.draw(in: body, angle: -45)
    let rose = NSColor(srgbRed: 0xf4 / 255, green: 0x3f / 255, blue: 0x5e / 255, alpha: 1)
    // Cassette blanche : corps, fenêtre évidée, bobines.
    let glyph = NSRect(x: 232, y: 332, width: 560, height: 350)
    let s = min(glyph.width / 64, glyph.height / 40)
    let ox = glyph.midX - 32 * s, oy = glyph.midY - 20 * s
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: ox + x * s, y: oy + (40 - y - h) * s, width: w * s, height: h * s) }
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (40 - y) * s) }
    rose.setFill()
    NSBezierPath(roundedRect: r(1, 1, 62, 38), xRadius: 5 * s, yRadius: 5 * s).fill()
    // Fenêtre et pied dans la couleur du fond (dégradé : on les peint par-dessus en rose moyen).
    let hole = NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x2b / 255, alpha: 1)
    hole.setFill()
    NSBezierPath(roundedRect: r(9, 8, 46, 16), xRadius: 3 * s, yRadius: 3 * s).fill()
    let base = NSBezierPath()
    base.move(to: p(16, 39)); base.line(to: p(20, 30)); base.line(to: p(44, 30)); base.line(to: p(48, 39)); base.close()
    base.fill()
    rose.setFill()
    NSBezierPath(ovalIn: r(16, 11, 10, 10)).fill()
    NSBezierPath(ovalIn: r(38, 11, 10, 10)).fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
