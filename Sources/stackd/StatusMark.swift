import AppKit
import Observation

/// The menu bar mark: an isometric pyramid of three cubes, drawn as a template `NSImage`
/// (black + alpha only, so macOS tints it for light/dark bars and the highlighted state).
enum StatusMark {
    enum Style: Sendable { case solid, outline }

    static let size = NSSize(width: 18, height: 18)

    /// Points per geometry unit (100-unit design space → ~16 pt wide pyramid in the 18 pt image).
    private static let unit: CGFloat = 0.28
    private static let k: CGFloat = 0.866
    private static let s: CGFloat = 17

    static func image(style: Style, badge: Bool, alpha: CGFloat) -> NSImage {
        let alpha = min(max(alpha, 0), 1)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, style: style, badge: badge, alpha: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Geometry

    /// Maps design units (y down) to points in the 18×18 image, centring the pyramid's bbox.
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - 50) * unit + 9, y: (y - 50) * unit + 9)
    }

    private static func faces(topCentre c: (x: CGFloat, y: CGFloat)) -> [[CGPoint]] {
        let x = c.x, y = c.y
        return [
            [pt(x, y - s / 2), pt(x + k * s, y), pt(x, y + s / 2), pt(x - k * s, y)],            // top
            [pt(x - k * s, y), pt(x, y + s / 2), pt(x, y + 1.5 * s), pt(x - k * s, y + s)],      // left
            [pt(x, y + s / 2), pt(x + k * s, y), pt(x + k * s, y + s), pt(x, y + 1.5 * s)],      // right
        ]
    }

    /// Cubes in painter's order, back to front: the two bottom cubes, then the top cube.
    private static var cubes: [(faces: [[CGPoint]], hull: [CGPoint])] {
        [(50 - k * s, 50), (50 + k * s, 50), (50, 50 - s)].map { c in
            let x = c.0, y = c.1
            let hull = [pt(x, y - s / 2), pt(x + k * s, y), pt(x + k * s, y + s),
                        pt(x, y + 1.5 * s), pt(x - k * s, y + s), pt(x - k * s, y)]
            return (faces(topCentre: c), hull)
        }
    }

    private static func path(_ poly: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: poly)
        p.closeSubpath()
        return p
    }

    // MARK: Drawing

    private static let seamWidth: CGFloat = 0.7
    private static let outlineWidth: CGFloat = 0.75

    private static func draw(in ctx: CGContext, style: Style, badge: Bool, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShouldAntialias(true)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        for cube in cubes {
            switch style {
            case .solid:
                // Fill re-covers seams cut under this cube; then cut this cube's own seams.
                ctx.setBlendMode(.normal)
                for f in cube.faces { ctx.addPath(path(f)); ctx.fillPath() }
                ctx.setBlendMode(.destinationOut)
                ctx.setLineWidth(seamWidth)
                for f in cube.faces { ctx.addPath(path(f)); ctx.strokePath() }
            case .outline:
                // Clear the silhouette so this cube occludes lines of cubes behind it.
                ctx.setBlendMode(.destinationOut)
                ctx.addPath(path(cube.hull)); ctx.fillPath()
                ctx.setBlendMode(.normal)
                ctx.setLineWidth(outlineWidth)
                for f in cube.faces { ctx.addPath(path(f)); ctx.strokePath() }
            }
        }
        ctx.setBlendMode(.normal)

        if badge { drawBadge(in: ctx) }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawBadge(in ctx: CGContext) {
        let centre = CGPoint(x: 14.8, y: 3.2)
        let r: CGFloat = 3.1
        let ring: CGFloat = 0.9
        func circle(_ rad: CGFloat) -> CGRect {
            CGRect(x: centre.x - rad, y: centre.y - rad, width: rad * 2, height: rad * 2)
        }
        // Transparent ring separating the badge from the pyramid.
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: circle(r + ring))
        // Filled disc.
        ctx.setBlendMode(.normal)
        ctx.fillEllipse(in: circle(r))
        // "!" cut out of the disc.
        ctx.setBlendMode(.destinationOut)
        let stem = CGRect(x: centre.x - 0.5, y: centre.y - 2.0, width: 1.0, height: 2.6)
        ctx.addPath(CGPath(roundedRect: stem, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: centre.x - 0.55, y: centre.y + 1.0, width: 1.1, height: 1.1))
        ctx.setBlendMode(.normal)
    }
}

// MARK: - Pulse driver (Connecting state)

/// Drives the pulsing alpha of the mark while connecting. The timer only runs while `isPulsing`.
@Observable @MainActor final class StatusPulse {
    static let period: TimeInterval = 1.6
    static let reducedMotionAlpha: CGFloat = 0.45

    /// Eases between 0.3 and 1.0 (cosine ease-in-out), continuous over `period`.
    static func alpha(at time: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        return 0.3 + 0.7 * (0.5 - 0.5 * CGFloat(cos(2 * .pi * phase)))
    }

    private(set) var alpha: CGFloat = 1
    private var isPulsing = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotionChanged() }
        }
    }

    /// Call whenever the "connecting" state changes.
    func setPulsing(_ pulsing: Bool) {
        isPulsing = pulsing
        apply()
    }

    private func reduceMotionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        apply()
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        guard isPulsing else { alpha = 1; return }
        if reduceMotion { alpha = Self.reducedMotionAlpha; return }
        let start = Date()
        alpha = Self.alpha(at: 0)
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.alpha = Self.alpha(at: Date().timeIntervalSince(start))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
