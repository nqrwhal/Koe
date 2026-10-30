// Prints 声 as half-block characters (▀ ▄ █) for install.sh's banner.
// usage: swift tools/make-banner.swift [rows] [font]
import AppKit

let rows = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 12
let fontName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "HiraMinProN-W6"
let height = rows * 2                     // two pixels per character cell
let width = Int(Double(height) * 2.0)     // terminal cells are about twice as tall as wide

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
context.setFillColor(gray: 0, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
// Squash horizontally so the glyph looks square once each cell is drawn twice as tall as wide.
context.scaleBy(x: 2, y: 1)
let font = NSFont(name: fontName, size: CGFloat(height) * 1.02)!
var character: UniChar = 0x58F0  // 声
var glyph: CGGlyph = 0
CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
let outline = font.boundingRect(forCGGlyph: glyph)
context.setFillColor(gray: 1, alpha: 1)
var position = CGPoint(x: Double(width) / 4 - outline.midX, y: Double(height) / 2 - outline.midY)
CTFontDrawGlyphs(font, &glyph, &position, 1, context)
NSGraphicsContext.restoreGraphicsState()

func on(_ x: Int, _ y: Int) -> Bool { rep.colorAt(x: x, y: y)!.whiteComponent > 0.42 }
for row in 0..<rows {
    var line = ""
    for x in 0..<width {
        switch (on(x, row * 2), on(x, row * 2 + 1)) {
        case (true, true): line += "█"
        case (true, false): line += "▀"
        case (false, true): line += "▄"
        default: line += " "
        }
    }
    print(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
}
