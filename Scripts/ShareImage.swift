import AppKit

// Compose the existing app icon and synthetic demo; never read account data.
private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

@MainActor
private final class ShareImageView: NSView {
    let icon: NSImage
    let preview: NSImage
    override var isFlipped: Bool { true }

    init(size: NSSize, icon: NSImage, preview: NSImage) {
        self.icon = icon
        self.preview = preview
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular, tint: NSColor = .white) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: tint
        ])
    }

    private func glow(x: CGFloat, y: CGFloat, radius: CGFloat, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: color(0x0B1424), ending: color(0x111831))!.draw(in: bounds, angle: 15)
        glow(x: bounds.width - 175, y: 90, radius: 520, tint: color(0x7460EF, alpha: 0.48))
        glow(x: bounds.width - 90, y: bounds.height - 20, radius: 450, tint: color(0x09B7B1, alpha: 0.23))
        glow(x: 230, y: 660, radius: 420, tint: color(0x365EAE, alpha: 0.14))

        for radius: CGFloat in [280, 390, 510] {
            let ring = NSBezierPath(ovalIn: NSRect(x: bounds.width - 170 - radius, y: 225 - radius,
                                                 width: radius * 2, height: radius * 2))
            color(0xB2BCFF, alpha: 0.075).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }

        icon.draw(in: NSRect(x: 52, y: 43, width: 82, height: 82), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        text("AI Credits", x: 150, y: 48, size: 62, weight: .bold)

        let badge = NSBezierPath(roundedRect: NSRect(x: 62, y: 149, width: 230, height: 31), xRadius: 15.5, yRadius: 15.5)
        color(0xA5B8EB, alpha: 0.09).setFill()
        badge.fill()
        color(0xBCD0FC, alpha: 0.22).setStroke()
        badge.lineWidth = 1
        badge.stroke()
        text("macOS 選單列工具  ·  MIT 開源", x: 76, y: 156, size: 13, weight: .medium, tint: color(0xD6E1F8))

        text("AI 額度與到期日", x: 60, y: 222, size: 57, weight: .semibold)
        text("一眼掌握。", x: 60, y: 295, size: 65, weight: .semibold, tint: color(0x87E6CE))
        text("額度追蹤  ·  到期提醒  ·  同步紀錄", x: 64, y: 393, size: 23, weight: .medium, tint: color(0xCCD7EC))

        text("OpenAI  /  Claude  /  Gemini  /  ElevenLabs", x: 64, y: 465, size: 18, weight: .medium, tint: color(0xB5C5E0))
        text("Lovable、Notion 支援手動管理", x: 64, y: 495, size: 16, tint: color(0x92A6C6))

        color(0xC9D6F0, alpha: 0.17).setFill()
        NSRect(x: 64, y: bounds.height - 73, width: 574, height: 1).fill()
        text("免費・開源・資料存於本機", x: 64, y: bounds.height - 49, size: 17, weight: .medium, tint: color(0xD8E3F5))
        text("github.com/Wolke/ai-credits", x: 380, y: bounds.height - 46, size: 15, tint: color(0x9BAECF))

        let panelWidth: CGFloat = 350
        let panelHeight = panelWidth * preview.size.height / preview.size.width
        let panel = NSRect(x: bounds.width - panelWidth - 48, y: (bounds.height - panelHeight) / 2 - 4,
                           width: panelWidth, height: panelHeight)
        let outline = NSBezierPath(roundedRect: panel, xRadius: 18, yRadius: 18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 32
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        preview.draw(in: panel, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        text("示範資料 · USD 換算為自訂估值", x: panel.minX + 74, y: panel.maxY + 13,
             size: 12, tint: color(0xB2C2DF))
    }
}

@main
struct ShareImage {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the project root") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")),
              let preview = NSImage(contentsOf: root.appendingPathComponent("docs/images/menu-preview.png")) else {
            fatalError("Missing app icon or synthetic preview; run Scripts/render-demo.sh first")
        }
        for (name, width, height) in [("facebook-cover", 1200, 630), ("social-preview", 1280, 640)] {
            let size = NSSize(width: width, height: height)
            let view = ShareImageView(size: size, icon: icon, preview: preview)
            view.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: true)
            window.contentView = view
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            precondition(png.count < 1_000_000, "GitHub social previews must be under 1 MB")
            try png.write(to: root.appendingPathComponent("docs/images/\(name).png"))
            print("Created \(name).png: \(width) × \(height), \(png.count) bytes")
        }
    }
}
