import AppKit

// Renders the app icon: the SunoFlow ear mark in white on a violet→indigo
// rounded-rect gradient. Usage:
//
//   make-icon <output.png> [pixel-size]     # pixel-size defaults to 1024
//
// The mark itself comes from BrandMark.swift, which holds the same SVG path
// data the website ships, so the app icon and the site can't drift apart.
// `tools/make-icns.sh` compiles the two together and wraps the result up as
// Resources/AppIcon.icns.

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let pixels = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
let size = CGFloat(pixels)

// Draw into a bitmap of exactly `pixels` square. Going through NSImage's
// lockFocus() instead would silently render at the main screen's backing scale,
// so the same command would produce a 2048px file on a Retina Mac and a 1024px
// one over SSH.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("could not allocate the bitmap")
}

guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("no graphics context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let ctx = context.cgContext

// Transparent margin around the rounded rect, matching macOS icon grid spacing.
let margin: CGFloat = size * 90 / 1024
let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let radius: CGFloat = (size - margin * 2) * 0.2237 // Apple squircle-ish corner
let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Background gradient.
let top = NSColor(calibratedRed: 0.486, green: 0.361, blue: 1.0, alpha: 1.0)   // #7C5CFF
let bottom = NSColor(calibratedRed: 0.294, green: 0.180, blue: 0.839, alpha: 1.0) // #4B2ED6
let gradient = NSGradient(colors: [top, bottom])!
bgPath.addClip()
gradient.draw(in: rect, angle: -90)
ctx.resetClip()

// Soft top highlight for a little depth.
let highlight = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.18),
    NSColor(white: 1.0, alpha: 0.0),
])!
bgPath.addClip()
highlight.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
ctx.resetClip()

// The ear, in white, sized to sit comfortably inside the rounded rect.
let glyph = rect.insetBy(dx: rect.width * 0.21, dy: rect.height * 0.21)
BrandMark.draw(.idle, in: glyph, color: NSColor.white.cgColor, into: ctx)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render PNG")
}

try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
