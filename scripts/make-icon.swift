// Draws the app icon into an .iconset folder: a sheet of paper with one blank already filled in.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    c.scaleBy(x: s, y: s)

    // Background tile: pen blue.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    c.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
    c.clip()
    let colors = [CGColor(srgbRed: 0.16, green: 0.33, blue: 0.86, alpha: 1), CGColor(srgbRed: 0.08, green: 0.19, blue: 0.62, alpha: 1)] as CFArray
    c.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!,
                         start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    c.resetClip()

    // Sheet, slightly turned.
    c.saveGState()
    c.translateBy(x: 512, y: 500)
    c.rotate(by: -0.07)
    let sheet = CGRect(x: -235, y: -300, width: 470, height: 610)
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.35))
    c.setFillColor(CGColor(srgbRed: 0.995, green: 0.99, blue: 0.975, alpha: 1))
    c.addPath(CGPath(roundedRect: sheet, cornerWidth: 26, cornerHeight: 26, transform: nil))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)

    // Printed lines.
    c.setFillColor(CGColor(gray: 0.2, alpha: 0.85))
    c.fill(CGRect(x: -180, y: 205, width: 230, height: 34))
    c.setFillColor(CGColor(gray: 0.55, alpha: 0.55))
    for (y, w) in [(120, 360), (70, 300)] as [(CGFloat, CGFloat)] { c.fill(CGRect(x: -180, y: y, width: w, height: 18)) }
    // Two blanks; the first is filled in with a pen stroke.
    c.setFillColor(CGColor(gray: 0.3, alpha: 0.8))
    c.fill(CGRect(x: -180, y: -70, width: 360, height: 8))
    c.fill(CGRect(x: -180, y: -200, width: 360, height: 8))
    c.setStrokeColor(CGColor(srgbRed: 0.11, green: 0.25, blue: 0.75, alpha: 1))
    c.setLineWidth(26); c.setLineCap(.round); c.setLineJoin(.round)
    c.move(to: CGPoint(x: -160, y: -20))
    c.addCurve(to: CGPoint(x: -60, y: -30), control1: CGPoint(x: -130, y: 50), control2: CGPoint(x: -95, y: -75))
    c.addCurve(to: CGPoint(x: 40, y: -25), control1: CGPoint(x: -30, y: 45), control2: CGPoint(x: 5, y: -70))
    c.addCurve(to: CGPoint(x: 150, y: -5), control1: CGPoint(x: 70, y: 30), control2: CGPoint(x: 110, y: -40))
    c.strokePath()
    // Cursor on the second blank.
    c.setFillColor(CGColor(srgbRed: 0.11, green: 0.25, blue: 0.75, alpha: 1))
    c.fill(CGRect(x: -170, y: -185, width: 14, height: 84))
    c.restoreGState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! icon(px).write(to: out.appendingPathComponent("\(name).png"))
}
