import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
let shape = NSBezierPath(roundedRect: rect, xRadius: 198, yRadius: 198)
NSGradient(starting: NSColor(calibratedRed: 0.19, green: 0.21, blue: 0.27, alpha: 1), ending: NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.09, alpha: 1))!.draw(in: shape, angle: -70)
let screen = NSBezierPath(roundedRect: NSRect(x: 223, y: 303, width: 578, height: 418), xRadius: 90, yRadius: 90)
NSColor(calibratedRed: 1, green: 0.40, blue: 0.31, alpha: 1).setStroke()
screen.lineWidth = 34; screen.stroke()
let play = NSBezierPath(); play.move(to: NSPoint(x: 453, y: 412)); play.line(to: NSPoint(x: 453, y: 612)); play.line(to: NSPoint(x: 617, y: 512)); play.close()
NSColor(calibratedRed: 1, green: 0.40, blue: 0.31, alpha: 1).setFill(); play.fill()
image.unlockFocus()
let directory = URL(fileURLWithPath: "assets/Luma.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for n in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = n * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(n)x\(n)\(suffix).png"))
    }
}
