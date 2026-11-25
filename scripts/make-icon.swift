// Renders the HomeNet Pulse app icon.  Usage: swift scripts/make-icon.swift <output-dir>
// Concept: a house (home network) whose interior carries a heartbeat "pulse" line,
// with Wi-Fi arcs as the roof's signal — on a deep blue → teal gradient.
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the artwork into a square of side `s` starting at origin (CG coordinates, y up).
func drawArtwork(_ ctx: CGContext, side s: CGFloat) {
    // Background gradient
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [color(0x0B3D91), color(0x0A6FD6), color(0x14B8A6)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Soft glow behind the house
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.45), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.45), endRadius: s * 0.48, options: [])

    // Optically centre the house + arcs composition.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: -s * 0.06)
    defer { ctx.restoreGState() }

    let white = color(0xFFFFFF)
    let line = s * 0.055
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // House outline
    let left = s * 0.24, right = s * 0.76, bottom = s * 0.22, wallTop = s * 0.52, apex = s * 0.72
    let house = CGMutablePath()
    house.move(to: CGPoint(x: left, y: wallTop))
    house.addLine(to: CGPoint(x: s * 0.5, y: apex))
    house.addLine(to: CGPoint(x: right, y: wallTop))
    house.addLine(to: CGPoint(x: right, y: bottom))
    house.addLine(to: CGPoint(x: left, y: bottom))
    house.closeSubpath()
    ctx.setStrokeColor(white)
    ctx.setLineWidth(line)
    ctx.addPath(house)
    ctx.strokePath()

    // Heartbeat pulse across the house, extending past the walls
    let y0 = s * 0.37
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: s * 0.12, y: y0))
    pulse.addLine(to: CGPoint(x: s * 0.36, y: y0))
    pulse.addLine(to: CGPoint(x: s * 0.42, y: y0 + s * 0.06))
    pulse.addLine(to: CGPoint(x: s * 0.49, y: y0 - s * 0.11))
    pulse.addLine(to: CGPoint(x: s * 0.56, y: y0 + s * 0.15))
    pulse.addLine(to: CGPoint(x: s * 0.62, y: y0))
    pulse.addLine(to: CGPoint(x: s * 0.88, y: y0))
    // Halo so the line reads where it crosses the walls
    ctx.setStrokeColor(color(0x0A4FB0, 0.9))
    ctx.setLineWidth(line * 2.1)
    ctx.addPath(pulse)
    ctx.strokePath()
    ctx.setStrokeColor(color(0x5EF2B8))
    ctx.setLineWidth(line)
    ctx.addPath(pulse)
    ctx.strokePath()

    // Wi-Fi arcs above the roof apex
    let c = CGPoint(x: s * 0.5, y: apex + s * 0.02)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(line * 0.8)
    for r in [s * 0.10, s * 0.17] {
        ctx.addArc(center: c, radius: r, startAngle: .pi * 0.30, endAngle: .pi * 0.70, clockwise: false)
        ctx.strokePath()
    }
}

func render(size: Int, mac: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    if mac {
        // macOS grid: 824/1024 rounded rectangle, centred, with a soft drop shadow.
        let inset = s * (100.0 / 1024.0)
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = rect.width * 0.225
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: color(0x000000, 0.35))
        ctx.addPath(shape); ctx.setFillColor(color(0x0B3D91)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        drawArtwork(ctx, side: rect.width)
        ctx.restoreGState()
    } else {
        drawArtwork(ctx, side: s)   // iOS: full bleed, the system applies the mask
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

save(render(size: 1024, mac: false), "AppIcon-iOS-1024.png")
for (px, name) in [(16, "16"), (32, "16@2x"), (32, "32"), (64, "32@2x"), (128, "128"), (256, "128@2x"),
                   (256, "256"), (512, "256@2x"), (512, "512"), (1024, "512@2x")] {
    save(render(size: px, mac: true), "AppIcon-mac-\(name).png")
}
