import AppKit

// Renders a 1024x1024 app icon: a white microphone glyph on a violet→indigo
// rounded-rect gradient, and writes it to the path given as argv[1].

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// Transparent margin around the rounded rect, matching macOS icon grid spacing.
let margin: CGFloat = 90
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

// White microphone glyph via SF Symbol, palette-colored white.
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig) {
    let s = mic.size
    let drawRect = NSRect(
        x: (size - s.width) / 2,
        y: (size - s.height) / 2,
        width: s.width,
        height: s.height
    )
    mic.draw(in: drawRect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render PNG")
}

try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
