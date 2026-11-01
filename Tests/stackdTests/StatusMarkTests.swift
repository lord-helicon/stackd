import AppKit
import Foundation
import Testing
@testable import stackd

struct StatusMarkTests {
    private static let previewDir = ProcessInfo.processInfo.environment["STACKD_PREVIEW_DIR"]

    /// Renders the image into an RGBA bitmap (premultiplied) at `scale`x.
    private func bitmap(_ image: NSImage, scale: Int = 1) -> NSBitmapImageRep {
        let w = Int(image.size.width) * scale, h = Int(image.size.height) * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: w, height: h))
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func alphaSum(_ rep: NSBitmapImageRep) -> Double {
        var sum = 0.0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            sum += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        } }
        return sum
    }

    @Test func allVariantsAre18ptTemplates() {
        for style in [StatusMark.Style.solid, .outline] {
            for badge in [false, true] {
                let image = StatusMark.image(style: style, badge: badge, alpha: 1)
                #expect(image.size == NSSize(width: 18, height: 18))
                #expect(image.isTemplate)
            }
        }
    }

    @Test func solidIsHeavierThanOutline() {
        let solid = alphaSum(bitmap(StatusMark.image(style: .solid, badge: false, alpha: 1), scale: 2))
        let outline = alphaSum(bitmap(StatusMark.image(style: .outline, badge: false, alpha: 1), scale: 2))
        #expect(solid > outline * 1.1)
        #expect(outline > 0)
    }

    @Test func badgeDiffersFromPlain() {
        let plain = bitmap(StatusMark.image(style: .solid, badge: false, alpha: 1), scale: 2)
        let badged = bitmap(StatusMark.image(style: .solid, badge: true, alpha: 1), scale: 2)
        #expect(abs(alphaSum(plain) - alphaSum(badged)) > 1)
    }

    @Test func alphaScalesOpacity() {
        let full = alphaSum(bitmap(StatusMark.image(style: .solid, badge: false, alpha: 1), scale: 2))
        let dim = alphaSum(bitmap(StatusMark.image(style: .solid, badge: false, alpha: 0.45), scale: 2))
        #expect(abs(dim / full - 0.45) < 0.03)
    }

    @MainActor @Test func pulseStaysInRangeAndLoops() {
        var lo = 1.0, hi = 0.0
        for i in 0...160 {
            let a = Double(StatusPulse.alpha(at: Double(i) * 0.01))
            lo = min(lo, a); hi = max(hi, a)
        }
        #expect(abs(lo - 0.3) < 0.01)
        #expect(abs(hi - 1.0) < 0.01)
        #expect(abs(StatusPulse.alpha(at: 0) - StatusPulse.alpha(at: 1.6)) < 0.001)
    }

    @Test func writePreviews() throws {
        guard let dir = Self.previewDir, !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let variants: [(String, StatusMark.Style, Bool, CGFloat)] = [
            ("solid", .solid, false, 1), ("solid-badge", .solid, true, 1),
            ("outline", .outline, false, 1), ("solid-alpha45", .solid, false, 0.45),
        ]
        for (name, style, badge, alpha) in variants {
            let rep = bitmap(StatusMark.image(style: style, badge: badge, alpha: alpha), scale: 4)
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            // White-on-#2b2b2e composite simulating a dark menu bar.
            let dark = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let bg = (0x2b / 255.0, 0x2b / 255.0, 0x2e / 255.0)
                dark.setColor(NSColor(deviceRed: bg.0 + (1 - bg.0) * a, green: bg.1 + (1 - bg.1) * a,
                                      blue: bg.2 + (1 - bg.2) * a, alpha: 1), atX: x, y: y)
            } }
            try dark.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "\(dir)/\(name)-dark.png"))
        }
    }
}
