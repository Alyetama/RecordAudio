import AppKit

// Renders a 1024×1024 macOS-style app icon for RecordAudio:
// a rounded-square (squircle-ish) tile with a violet→magenta→coral gradient,
// a soft drop shadow, a top sheen, and a white audio-waveform in the center.

let side: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side), pixelsHigh: Int(side),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("rep") }

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// The tile, inset to leave room for the drop shadow.
let inset: CGFloat = 96
let rect = CGRect(x: inset, y: inset, width: side - 2*inset, height: side - 2*inset)
let radius = rect.width * 0.2237
let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 1) Drop shadow (cast by an opaque fill of the tile shape).
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -20), blur: 46,
             color: NSColor.black.withAlphaComponent(0.34).cgColor)
cg.addPath(tile)
cg.setFillColor(NSColor.black.cgColor)
cg.fillPath()
cg.restoreGState()

// 2) Gradient fill, clipped to the tile.
cg.saveGState()
cg.addPath(tile)
cg.clip()

let grad = CGGradient(colorsSpace: srgb, colors: [
    NSColor(srgbRed: 0.49, green: 0.20, blue: 0.96, alpha: 1).cgColor, // violet
    NSColor(srgbRed: 0.80, green: 0.16, blue: 0.72, alpha: 1).cgColor, // magenta
    NSColor(srgbRed: 1.00, green: 0.24, blue: 0.42, alpha: 1).cgColor  // coral-red
] as CFArray, locations: [0.0, 0.52, 1.0])!
cg.drawLinearGradient(grad,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end:   CGPoint(x: rect.maxX, y: rect.minY),
    options: [])

// 3) Soft top sheen.
let sheen = CGGradient(colorsSpace: srgb, colors: [
    NSColor.white.withAlphaComponent(0.30).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor
] as CFArray, locations: [0.0, 1.0])!
cg.drawRadialGradient(sheen,
    startCenter: CGPoint(x: rect.midX, y: rect.maxY - 40), startRadius: 0,
    endCenter:   CGPoint(x: rect.midX, y: rect.maxY - 40), endRadius: rect.width * 0.72,
    options: [])
cg.restoreGState()

// 4) White audio waveform (rounded bars), mirrored around the center line.
let heights: [CGFloat] = [0.30, 0.52, 0.40, 0.72, 0.56, 0.92, 1.0, 0.92, 0.56, 0.72, 0.40, 0.52, 0.30]
let barW: CGFloat = 26
let gap: CGFloat = 20
let maxH: CGFloat = 470
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = side/2 - totalW/2
let midY = side/2

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 16,
             color: NSColor.black.withAlphaComponent(0.20).cgColor)
cg.setFillColor(NSColor.white.cgColor)
for h in heights {
    let bh = max(barW, maxH * h)
    let bar = CGRect(x: x, y: midY - bh/2, width: barW, height: bh)
    cg.addPath(CGPath(roundedRect: bar, cornerWidth: barW/2, cornerHeight: barW/2, transform: nil))
    cg.fillPath()
    x += barW + gap
}
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! data.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("wrote icon_1024.png")
