// Renders the app icon (1024px) and writes an .iconset. Usage: swift scripts/make-icon.swift <out-dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1),
                        NSColor(red: 0.20, green: 0.16, blue: 0.38, alpha: 1)])!.draw(in: bg, angle: -60)
    // bars
    let colors: [NSColor] = [NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), NSColor(red: 0.20, green: 0.70, blue: 0.58, alpha: 1),
                             NSColor(red: 0.40, green: 0.48, blue: 0.98, alpha: 1), NSColor(red: 0.90, green: 0.70, blue: 0.20, alpha: 1)]
    let heights: [CGFloat] = [300, 470, 380, 580]
    for (i, h) in heights.enumerated() {
        let x = (240 + CGFloat(i) * 145) * s
        let r = NSRect(x: x, y: 240 * s, width: 100 * s, height: h * s)
        colors[i].setFill()
        NSBezierPath(roundedRect: r, xRadius: 26 * s, yRadius: 26 * s).fill()
    }
    // sparkle line
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 230 * s, y: 600 * s))
    line.curve(to: NSPoint(x: 790 * s, y: 860 * s), controlPoint1: NSPoint(x: 420 * s, y: 760 * s), controlPoint2: NSPoint(x: 600 * s, y: 640 * s))
    line.lineWidth = 26 * s; line.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke(); line.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 760 * s, y: 830 * s, width: 60 * s, height: 60 * s)).fill()
    img.unlockFocus()
    return img
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let img = render(CGFloat(px))
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
