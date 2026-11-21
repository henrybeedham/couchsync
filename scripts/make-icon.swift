// Draws the app icon to a 1024px PNG. Usage: swift make-icon.swift out.png
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded tile, inset the way macOS icons are.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 0.16, green: 0.10, blue: 0.36, alpha: 1),
    NSColor(red: 0.05, green: 0.04, blue: 0.14, alpha: 1),
])!.draw(in: shape, angle: -90)

// Two play triangles, one trailing the other: the same moment on two screens.
func triangle(centerX: Double, centerY: Double, side: Double) -> NSBezierPath {
    let h = side * 0.866
    let path = NSBezierPath()
    path.move(to: NSPoint(x: centerX - h / 3, y: centerY + side / 2))
    path.line(to: NSPoint(x: centerX + 2 * h / 3, y: centerY))
    path.line(to: NSPoint(x: centerX - h / 3, y: centerY - side / 2))
    path.close()
    path.lineJoinStyle = .round
    path.lineWidth = 44
    return path
}

let back = triangle(centerX: 420, centerY: 512, side: 300)
NSColor(red: 0.45, green: 0.36, blue: 0.80, alpha: 1).set()
back.fill(); back.stroke()

let front = triangle(centerX: 580, centerY: 512, side: 300)
NSColor.white.set()
front.fill(); front.stroke()

NSGraphicsContext.current?.flushGraphics()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
