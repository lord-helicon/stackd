// Renders the Stackd app icon: an isometric pyramid of three cubes on a graphite tile.
// Usage: swift Tools/render-icon.swift <out-dir>
// Writes <out-dir>/AppIcon.iconset (for `iconutil -c icns`), plus full-canvas, unmasked layers for
// Icon Composer (layers/background.png, layers/foreground.png and .svg variants).
import AppKit
import CoreGraphics

let K = 0.866, S = 17.0
let faceTop = (r: 1.0, g: 1.0, b: 1.0)
let faceLeft = (r: 0xc9 / 255.0, g: 0xcc / 255.0, b: 0xd3 / 255.0)
let faceRight = (r: 0x9e / 255.0, g: 0xa3 / 255.0, b: 0xad / 255.0)
let bgTop = (r: 0x3a / 255.0, g: 0x3d / 255.0, b: 0x44 / 255.0)
let bgBottom = (r: 0x17 / 255.0, g: 0x18 / 255.0, b: 0x1c / 255.0)

typealias P = (x: Double, y: Double)  // design space: 100x100, y down

struct Face { let pts: [P]; let color: (r: Double, g: Double, b: Double) }

func cubeFaces(_ x: Double, _ y: Double) -> [Face] {
    [
        Face(pts: [(x, y - S / 2), (x + K * S, y), (x, y + S / 2), (x - K * S, y)], color: faceTop),
        Face(pts: [(x - K * S, y), (x, y + S / 2), (x, y + 1.5 * S), (x - K * S, y + S)], color: faceLeft),
        Face(pts: [(x, y + S / 2), (x + K * S, y), (x + K * S, y + S), (x, y + 1.5 * S)], color: faceRight),
    ]
}
// Top cube is drawn last.
let faces = cubeFaces(50 - K * S, 50) + cubeFaces(50 + K * S, 50) + cubeFaces(50, 50 - S)

func cgColor(_ c: (r: Double, g: Double, b: Double)) -> CGColor {
    CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
}

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

/// Rounded square with macOS-style continuous (smoothed) corners, radius r. rect in pixels.
/// Corner curves span ~1.53r along each edge (Apple's continuous-corner construction).
func squirclePath(_ rect: CGRect, radius r: Double) -> CGPath {
    let path = CGMutablePath()
    // Corner offsets measured from the corner point, in units of r: (along-edge, inward).
    // Each corner is built in a local frame where the corner is at the origin, x runs along the
    // first edge and y along the second, then mapped onto the four corners.
    func corner(_ origin: CGPoint, _ ex: CGVector, _ ey: CGVector, first: Bool) {
        func pt(_ a: Double, _ b: Double) -> CGPoint {
            CGPoint(x: origin.x + (ex.dx * a + ey.dx * b) * r, y: origin.y + (ex.dy * a + ey.dy * b) * r)
        }
        if first { path.move(to: pt(1.52866, 0)) } else { path.addLine(to: pt(1.52866, 0)) }
        path.addCurve(to: pt(0.63149, 0.07491), control1: pt(1.08849, 0), control2: pt(0.86840, 0))
        path.addCurve(to: pt(0.07491, 0.63149), control1: pt(0.37282, 0.16906), control2: pt(0.16906, 0.37282))
        path.addCurve(to: pt(0, 1.52866), control1: pt(0, 0.86840), control2: pt(0, 1.08849))
    }
    // Clockwise in CG's y-up space; each corner starts on its incoming edge, ends on the outgoing one.
    corner(CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), first: true)
    corner(CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1), first: false)
    corner(CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0), first: false)
    corner(CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), first: false)
    path.closeSubpath()
    return path
}

func drawGradient(_ ctx: CGContext, rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [cgColor(bgTop), cgColor(bgBottom)] as CFArray, locations: [0, 1])!
    // CG origin is bottom-left: top colour at maxY.
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// Draws the cubes so the pyramid is `widthFraction` of `width`, centred on `center` (pixels, CG coords).
func drawCubes(_ ctx: CGContext, center: CGPoint, width: Double, widthFraction: Double) {
    let scale = width * widthFraction / (2 * (K * S * 2))  // pyramid is 4*K*S = 58.8 units wide
    for f in faces {
        let path = CGMutablePath()
        for (i, p) in f.pts.enumerated() {
            let pt = CGPoint(x: center.x + (p.x - 50) * scale, y: center.y - (p.y - 50) * scale)
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        path.closeSubpath()
        ctx.setFillColor(cgColor(f.color))
        ctx.addPath(path)
        ctx.fillPath()
        // Hairline stroke in the face colour closes anti-aliasing seams between adjoining faces.
        ctx.setStrokeColor(cgColor(f.color))
        ctx.setLineWidth(max(0.25, scale * 0.12))
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
    }
}

enum Mode { case icon, background, foreground }

func render(px: Int, mode: Mode) -> CGImage {
    let ctx = makeContext(px)
    let canvas = Double(px)
    switch mode {
    case .icon:
        // macOS grid: 824/1024 tile, centred. Pyramid ≈ 70% of tile width.
        let side = canvas * 824 / 1024
        let rect = CGRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
        ctx.saveGState()
        ctx.addPath(squirclePath(rect, radius: side * 185 / 824)); ctx.clip()
        drawGradient(ctx, rect: rect)
        ctx.restoreGState()
        drawCubes(ctx, center: CGPoint(x: canvas / 2, y: canvas / 2), width: side, widthFraction: 0.70)
    case .background:
        drawGradient(ctx, rect: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    case .foreground:
        // Unmasked layer: the system applies the shape, so size relative to the full canvas.
        drawCubes(ctx, center: CGPoint(x: canvas / 2, y: canvas / 2), width: canvas, widthFraction: 0.70)
    }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
}

func svg(mode: Mode) -> String {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
    if mode == .background {
        s += "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(hex(bgTop))\"/><stop offset=\"1\" stop-color=\"\(hex(bgBottom))\"/></linearGradient></defs>\n"
        s += "<rect width=\"1024\" height=\"1024\" fill=\"url(#g)\"/>\n"
    } else {
        let scale = 1024 * 0.70 / (4 * K * S)
        for f in faces {
            let pts = f.pts.map { String(format: "%.2f,%.2f", 512 + ($0.x - 50) * scale, 512 + ($0.y - 50) * scale) }
            s += "<polygon points=\"\(pts.joined(separator: " "))\" fill=\"\(hex(f.color))\" stroke=\"\(hex(f.color))\" stroke-width=\"\(String(format: "%.2f", scale * 0.12))\" stroke-linejoin=\"round\"/>\n"
        }
    }
    return s + "</svg>\n"
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift render-icon.swift <out-dir>\n".utf8)); exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let layers = out.appendingPathComponent("layers", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: layers, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        writePNG(render(px: base * scale, mode: .icon), iconset.appendingPathComponent(name))
    }
}
writePNG(render(px: 1024, mode: .icon), out.appendingPathComponent("icon-1024.png"))
writePNG(render(px: 1024, mode: .background), layers.appendingPathComponent("background.png"))
writePNG(render(px: 1024, mode: .foreground), layers.appendingPathComponent("foreground.png"))
try svg(mode: .background).write(to: layers.appendingPathComponent("background.svg"), atomically: true, encoding: .utf8)
try svg(mode: .foreground).write(to: layers.appendingPathComponent("foreground.svg"), atomically: true, encoding: .utf8)
print("Wrote \(out.path)")
