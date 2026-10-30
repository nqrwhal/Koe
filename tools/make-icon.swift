// Draws Koe's app icon — 声 as a vermilion seal — and writes Resources/AppIcon.icns.
// usage: swift tools/make-icon.swift   (run from the repo root)
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024

    // macOS icon grid: an 824-point body centred in the 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 24 * scale
    shadow.set()
    NSColor(srgbRed: 0.80, green: 0.22, blue: 0.16, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Seal-ink red, slightly lighter at the top.
    NSGradient(
        starting: NSColor(srgbRed: 0.86, green: 0.27, blue: 0.19, alpha: 1),
        ending: NSColor(srgbRed: 0.74, green: 0.18, blue: 0.13, alpha: 1)
    )!.draw(in: shape, angle: -90)

    // Inner seal border.
    let inset = body.insetBy(dx: 64 * scale, dy: 64 * scale)
    let border = NSBezierPath(roundedRect: inset, xRadius: 120 * scale, yRadius: 120 * scale)
    border.lineWidth = 14 * scale
    NSColor(srgbRed: 0.98, green: 0.94, blue: 0.88, alpha: 0.85).setStroke()
    border.stroke()

    // Centre the character by its outline, not its line box.
    let font = NSFont(name: "HiraMinProN-W6", size: 470 * scale) ?? .boldSystemFont(ofSize: 470 * scale)
    var character: UniChar = 0x58F0  // 声
    var glyph: CGGlyph = 0
    CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
    let outline = font.boundingRect(forCGGlyph: glyph)
    let context = NSGraphicsContext.current!.cgContext
    context.setFillColor(NSColor(srgbRed: 0.98, green: 0.94, blue: 0.88, alpha: 1).cgColor)
    var position = CGPoint(x: body.midX - outline.midX, y: body.midY - outline.midY)
    CTFontDrawGlyphs(font, &glyph, &position, 1, context)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! render(size: CGFloat(points * factor)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
