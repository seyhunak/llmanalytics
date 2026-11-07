// Renders the app icon and writes an .iconset. Usage: swift scripts/make-icon.swift <out-dir>
//
// Design: a macOS-style squircle with a deep indigo gradient, a usage ring split into the editor
// colors (Claude coral, Codex teal, Cursor blue, Gemini amber) and an AI sparkle in the middle.
// Drawn with Core Graphics at exact pixel sizes so every slot in the .iconset is crisp.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Continuous-corner rounded square (superellipse), like the macOS icon shape.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n = 4.3, steps = 360
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = cy + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// Four-point sparkle with concave sides.
func sparkle(center c: CGPoint, radius R: CGFloat, pinch: CGFloat = 0.14) -> CGPath {
    let p = CGMutablePath()
    let k = R * pinch
    p.move(to: CGPoint(x: c.x, y: c.y + R))
    p.addQuadCurve(to: CGPoint(x: c.x + R, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - R), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - R, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + R), control: CGPoint(x: c.x - k, y: c.y + k))
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let small = px <= 32   // simplify details that turn to mush at tiny sizes

    // Body: Apple's grid puts the 824 pt shape inside a 1024 canvas, leaving room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x14123a)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // Base gradient: indigo at the top to near-black navy at the bottom.
    let base = CGGradient(colorsSpace: srgb, colors: [rgb(0x312e81), rgb(0x1e1b4b), rgb(0x0b0f24)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft violet glow behind the ring.
    let glow = CGGradient(colorsSpace: srgb, colors: [rgb(0x8b5cf6, 0.55), rgb(0x8b5cf6, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 530), endRadius: 400, options: [])
    // Glassy sheen across the top third.
    let sheen = CGGradient(colorsSpace: srgb, colors: [rgb(0xffffff, 0.16), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    // Hairline rim light.
    if !small {
        ctx.saveGState()
        ctx.addPath(squircle(body.insetBy(dx: 3, dy: 3)))
        ctx.setStrokeColor(rgb(0xffffff, 0.14)); ctx.setLineWidth(4); ctx.strokePath()
        ctx.restoreGState()
    }

    // Usage ring: editor-colored segments, clockwise from 12 o'clock.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 262
    let width: CGFloat = small ? 96 : 74
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(rgb(0xffffff, 0.08))
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()

    let segments: [(CGFloat, UInt32, UInt32)] = [   // share, color, lighter tint
        (0.40, 0xe0795a, 0xf4a483),   // coral
        (0.26, 0x2fb59a, 0x6ee7c8),   // teal
        (0.21, 0x5b6cf5, 0x93a0ff),   // blue
        (0.13, 0xf2b631, 0xfcd877),   // amber
    ]
    let gap: CGFloat = small ? 0.05 : 0.075          // radians-ish gap, keeps round caps apart
    var angle = CGFloat.pi / 2                       // start at 12 o'clock
    for (share, color, light) in segments {
        let sweep = share * 2 * .pi
        let start = angle - gap / 2 - width / radius / 2
        let end = angle - sweep + gap / 2 + width / radius / 2
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: small ? 0 : 22, color: rgb(color, 0.65))
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let g = CGGradient(colorsSpace: srgb, colors: [rgb(light), rgb(color)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 512 + radius + width), end: CGPoint(x: 512, y: 512 - radius - width), options: [])
        ctx.restoreGState()
        // Re-stroke for the glow (clip above swallows the shadow).
        if !small {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 26, color: rgb(color, 0.5))
            ctx.setStrokeColor(rgb(color, 0.01))
            ctx.setLineWidth(width)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            ctx.strokePath()
            ctx.restoreGState()
        }
        angle -= sweep
    }

    // Central sparkle with a glow, plus a small companion sparkle.
    let main = sparkle(center: CGPoint(x: 512, y: 512), radius: small ? 170 : 150)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: small ? 0 : 40, color: rgb(0xc4b5fd, 0.9))
    ctx.addPath(main); ctx.setFillColor(rgb(0xffffff)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(main); ctx.clip()
    let sg = CGGradient(colorsSpace: srgb, colors: [rgb(0xffffff), rgb(0xe9e3ff)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sg, start: CGPoint(x: 512, y: 662), end: CGPoint(x: 512, y: 362), options: [])
    ctx.restoreGState()
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xc4b5fd, 0.8))
        ctx.addPath(sparkle(center: CGPoint(x: 618, y: 620), radius: 44, pinch: 0.12))
        ctx.setFillColor(rgb(0xffffff, 0.95)); ctx.fillPath()
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    writePNG(render(px), "\(out)/icon_\(name).png")
}
