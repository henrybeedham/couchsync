// Draws the link-preview card (1280×640) from the app icon.
// Usage: swift make-social.swift icon-1024.png out.png
import AppKit

let width = 1280.0, height = 640.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Background: the icon's purple, with a soft glow behind the icon.
NSGradient(colors: [
    NSColor(red: 0.13, green: 0.08, blue: 0.30, alpha: 1),
    NSColor(red: 0.04, green: 0.03, blue: 0.11, alpha: 1),
])!.draw(in: canvas, angle: -90)
NSGradient(colors: [
    NSColor(red: 0.45, green: 0.36, blue: 0.80, alpha: 0.45),
    NSColor(red: 0.45, green: 0.36, blue: 0.80, alpha: 0),
])!.draw(fromCenter: NSPoint(x: 300, y: 320), radius: 0,
         toCenter: NSPoint(x: 300, y: 320), radius: 420, options: [])

// Icon (its PNG has macOS's built-in margin).
let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!
icon.draw(in: NSRect(x: 60, y: 80, width: 480, height: 480))

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}
func draw(_ text: String, _ f: NSFont, _ color: NSColor, x: Double, y: Double) {
    NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color])
        .draw(at: NSPoint(x: x, y: y))
}

let left = 560.0
draw("CouchSync", font(116, .bold), .white, x: left, y: 330)
draw("Watch Netflix together", font(46, .semibold),
     NSColor(red: 0.80, green: 0.76, blue: 1, alpha: 1), x: left + 4, y: 262)
draw("on every Mac.", font(46, .semibold),
     NSColor(red: 0.80, green: 0.76, blue: 1, alpha: 1), x: left + 4, y: 206)
draw("Synced playback · Chat · GIFs · Reactions", font(27, .medium),
     NSColor(white: 1, alpha: 0.55), x: left + 6, y: 138)

NSGraphicsContext.current?.flushGraphics()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
