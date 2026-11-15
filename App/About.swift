// mTAPES — fenêtre « À propos » (modèle Socle : swift/AboutWindow.swift, 356 px, marges de 28).
import AppKit

@MainActor
enum About {
    private static var window: NSWindow?
    private static let sideMargin: CGFloat = 28
    private static let textWidth: CGFloat = 300
    static let brandColor = NSColor(srgbRed: 0xf4 / 255, green: 0x3f / 255, blue: 0x5e / 255, alpha: 1)

    static func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        window?.present()
    }

    private static func label(_ text: String, size: CGFloat = 12, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.alignment = .center
        field.preferredMaxLayoutWidth = textWidth
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        return field
    }

    private static func nameLabel() -> NSTextField {
        let f = label("mTAPES", size: 17, bold: true)
        let s = NSMutableAttributedString(string: "mTAPES", attributes: [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.labelColor])
        s.addAttribute(.foregroundColor, value: brandColor, range: NSRange(location: 0, length: 1))
        f.attributedStringValue = s
        f.alignment = .center
        return f
    }

    /// « Fait partie du » puis le nom de la collection, non traduit.
    private static func collectionLabel() -> NSTextField {
        let text = "\(L.t("about.collection"))\nDESKTOP MAC TOOLKIT"
        let f = label(text, secondary: true)
        let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        let r = (text as NSString).range(of: "DESKTOP MAC TOOLKIT")
        s.addAttributes([.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .kern: 0.5], range: r)
        let p = NSMutableParagraphStyle(); p.alignment = .center
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        f.attributedStringValue = s
        return f
    }

    private static func makeWindow() -> NSWindow {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let views: [NSView] = [
            icon, nameLabel(),
            label(L.t("about.version", version, build), secondary: true),
            label(L.t("about.tagline")),
            collectionLabel(),
            label(L.t("about.authors"), bold: true),
            label(L.t("about.license")),
            label(L.t("about.disclaimer"), secondary: true),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: views[1])
        stack.setCustomSpacing(18, after: views[2])
        stack.edgeInsets = NSEdgeInsets(top: 28, left: sideMargin, bottom: 28, right: sideMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: textWidth + 2 * sideMargin).isActive = true

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L.t("about.menu")
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        return window
    }
}
