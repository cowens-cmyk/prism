// Draws Prism's app icon: a rounded glass prism on dark graphite, lit from
// inside by the colours the app paints its own window with. Full-bleed
// 1024 px; macOS rounds the corners.
//
//     swift tools/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// CoreGraphics' origin is bottom-left; flip so y grows downward like the sketch.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Background: graphite, a little lighter at the top.
let background = CGGradient(colorsSpace: space, colors: [color(0.19, 0.19, 0.22), color(0.06, 0.06, 0.08)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])


// The prism: an upright triangle.
let apex = CGPoint(x: 500, y: 250)
let left = CGPoint(x: 260, y: 700)
let right = CGPoint(x: 740, y: 700)
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
let entry = lerp(left, apex, 0.42)   // where white light goes// The prism: a triangle with rounded corners, apex up.
func roundedTriangle(_ points: [CGPoint], radius: Double) -> CGPath {
    let path = CGMutablePath()
    let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    path.move(to: mid(points[2], points[0]))
    for i in 0..<3 {
        path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % 3], radius: radius)
    }
    path.closeSubpath()
    return path
}
let corners = [CGPoint(x: 512, y: 190), CGPoint(x: 850, y: 780), CGPoint(x: 174, y: 780)]
let prism = roundedTriangle(corners, radius: 90)

// Light spilling onto the "floor" under the prism, in its colours.
for (x, c) in [(360.0, color(1, 0.2, 0.75, 0.38)), (512.0, color(0.55, 0.3, 1, 0.38)), (664.0, color(0.1, 0.75, 1, 0.38))] {
    let spill = CGGradient(colorsSpace: space, colors: [c, color(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spill, startCenter: CGPoint(x: x, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: x, y: 820), endRadius: 330, options: [])
}

// Inside the glass: the colours, blended corner to corner.
ctx.saveGState()
ctx.addPath(prism)
ctx.clip()
let fill = CGGradient(colorsSpace: space, colors: [
    color(1.0, 0.25, 0.7), color(0.62, 0.3, 1.0), color(0.2, 0.45, 1.0), color(0.1, 0.85, 0.85),
] as CFArray, locations: [0, 0.38, 0.7, 1])!
ctx.drawLinearGradient(fill, start: CGPoint(x: 200, y: 260), end: CGPoint(x: 840, y: 800), options: [])
// A bright core, as if lit from inside.
let core = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.7), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(core, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 260, options: [])
// Glass: a sheen across the top that fades out halfway down.
let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.45), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 190), end: CGPoint(x: 512, y: 520), options: [])
ctx.restoreGState()

// The rim: bright on top, softer below, with a glow of its own.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: color(0.75, 0.55, 1, 0.8))
ctx.addPath(prism)
ctx.setStrokeColor(color(1, 1, 1, 0.75))
ctx.setLineWidth(12)
ctx.strokePath()
ctx.restoreGState()
// A specular highlight along the upper left edge.
ctx.saveGState()
ctx.setStrokeColor(color(1, 1, 1, 0.9))
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 438, y: 330))
ctx.addLine(to: CGPoint(x: 330, y: 520))
ctx.strokePath()
ctx.restoreGState()

// Write the PNGs macOS asks for.
let image = ctx.makeImage()!
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let small = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: small.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": entries, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) sizes to \(folder.path)")
