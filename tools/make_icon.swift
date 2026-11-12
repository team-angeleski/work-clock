// Draws the app icon: the clock's buddy, happy, inside its progress ring, on a dark macOS tile.
// Usage: swift tools/make_icon.swift out.png   (1024×1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }

// Tile on Apple's macOS icon grid: 824pt body, centered, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(c(28, 28, 34)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: rgb, colors: [c(52, 50, 62), c(22, 22, 28)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Glassy top sheen
let sheen = CGGradient(colorsSpace: rgb, colors: [c(255, 255, 255, 0.10), c(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()
// Hairline edge
ctx.addPath(tilePath); ctx.setStrokeColor(c(255, 255, 255, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

let center = CGPoint(x: 512, y: 512)

// Progress ring: a faint track, then ~78% in orange → pink, starting at 12 o'clock going clockwise.
let ringR: CGFloat = 300, ringW: CGFloat = 58
ctx.setLineWidth(ringW); ctx.setLineCap(.round)
ctx.addArc(center: center, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.setStrokeColor(c(255, 255, 255, 0.09)); ctx.strokePath()
let start = CGFloat.pi / 2, end = start - 0.78 * .pi * 2
ctx.saveGState()
ctx.addArc(center: center, radius: ringR, startAngle: start, endAngle: end, clockwise: true)
ctx.replacePathWithStrokedPath(); ctx.clip()
let ring = CGGradient(colorsSpace: rgb, colors: [c(255, 176, 72), c(255, 112, 96), c(246, 82, 140)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(ring, start: CGPoint(x: 700, y: 820), end: CGPoint(x: 260, y: 220), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// The buddy: peach face with a warm glow.
let faceR: CGFloat = 205
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 40, color: c(255, 150, 90, 0.45))
ctx.addEllipse(in: CGRect(x: center.x - faceR, y: center.y - faceR, width: faceR * 2, height: faceR * 2))
ctx.setFillColor(c(250, 196, 160)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - faceR, y: center.y - faceR, width: faceR * 2, height: faceR * 2)); ctx.clip()
let face = CGGradient(colorsSpace: rgb, colors: [c(255, 222, 196), c(244, 170, 128)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: 512, y: 717), end: CGPoint(x: 512, y: 307), options: [])
ctx.restoreGState()

// Blush
for dx in [-118.0, 118.0] {
    ctx.addEllipse(in: CGRect(x: center.x + dx - 42, y: center.y - 48, width: 84, height: 46))
    ctx.setFillColor(c(240, 96, 110, 0.55)); ctx.fillPath()
}

// Happy ^ ^ eyes
let ink = c(52, 34, 34)
ctx.setStrokeColor(ink); ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for dx in [-82.0, 82.0] {
    ctx.move(to: CGPoint(x: center.x + dx - 38, y: center.y + 34))
    ctx.addQuadCurve(to: CGPoint(x: center.x + dx + 38, y: center.y + 34), control: CGPoint(x: center.x + dx, y: center.y + 100))
    ctx.strokePath()
}

// Smile
ctx.setLineWidth(24)
ctx.move(to: CGPoint(x: center.x - 52, y: center.y - 70))
ctx.addQuadCurve(to: CGPoint(x: center.x + 52, y: center.y - 70), control: CGPoint(x: center.x, y: center.y - 128))
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
