import AppKit
import Foundation
import SwiftUI
import Testing
@testable import stackd

/// Renders the README screenshot from the real `MenuBarView` with invented data.
/// Runs only when `STACKD_SCREENSHOT_DIR` is set:
/// `STACKD_SCREENSHOT_DIR=$PWD/docs swift test --filter ScreenshotTests`
@MainActor
struct ScreenshotTests {
    private static let outputDir = ProcessInfo.processInfo.environment["STACKD_SCREENSHOT_DIR"]

    private static func demoState() throws -> AppState {
        var billing = ProtoWriter()
        billing.appendString(11, "credits")
        billing.appendString(12, "eur")
        billing.appendInt64(10, 42_000_000) // €42.00
        var ident = ProtoWriter()
        ident.appendString(1, "demo-user")
        ident.appendString(5, "Demo User")
        ident.appendMessage(4, billing)

        func vm(_ name: String, _ status: String, _ vcpu: UInt32, _ gib: UInt64) throws -> Vm {
            var w = ProtoWriter()
            w.appendString(1, "demo-\(name)")
            w.appendString(2, name)
            w.appendString(5, status)
            w.appendString(12, "boxd.sh")
            w.appendUInt32(15, vcpu)
            w.appendUInt64(16, gib << 30)
            return try Vm(proto: w.data)
        }
        return AppState.demo(
            identity: try Identity(proto: ident.data),
            vms: [
                try vm("web", "running", 2, 8), try vm("api", "running", 4, 16),
                try vm("worker", "standby", 2, 8), try vm("nightly-jobs", "hibernated", 1, 4),
                try vm("staging", "stopped", 2, 8),
            ],
            lastRefresh: .now.addingTimeInterval(-2))
    }

    /// The real panel sits on a window material that isn't drawn offscreen, so draw an equivalent.
    private struct Framed: View {
        let state: AppState
        let scheme: ColorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            let dark = scheme == .dark
            MenuBarView(state: state)
                .background(dark ? Color(red: 0.150, green: 0.150, blue: 0.155)
                                 : Color(red: 0.935, green: 0.935, blue: 0.945))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.16 : 0.0)
                    .blendMode(.plusLighter), lineWidth: 1))
                .overlay(shape.strokeBorder(Color.black.opacity(dark ? 0.5 : 0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.22), radius: 14, y: -8) // cacheDisplay flips the shadow offset
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 44)
                .environment(\.colorScheme, scheme)
        }
    }

    /// Hosts the view in an offscreen window and snapshots it at 2x. `ImageRenderer` draws AppKit-backed
    /// controls (the row `Menu`s) as yellow "not allowed" placeholders; a real hosting view does not.
    private func render(_ content: some View, dark: Bool) throws -> Data {
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func writeScreenshots() throws {
        guard let dir = Self.outputDir, !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let state = try Self.demoState()
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            let png = try render(Framed(state: state, scheme: scheme), dark: scheme == .dark)
            try png.write(to: URL(fileURLWithPath: "\(dir)/screenshot-\(name).png"))
        }
    }
}
