import AppKit

/// The SunoFlow brand mark — an ear receiving sound.
///
/// The path strings below are copied verbatim from the website's wordmark
/// (`site/assets/favicon.svg`, and the `<svg>` inside every page's `.wordmark`),
/// so the menu bar, the app icon and the web app cannot drift apart. They are
/// SVG path data in a 24x24 box, stroked at width 2 with round caps and joins.
///
/// Nothing here depends on the rest of the app, so `tools/make-icon.swift` can
/// be compiled against this file to render the `.icns` from the same geometry.
enum BrandMark {

    // MARK: - The mark

    /// The outer ear. A closed subpath, so it can also be filled as a silhouette.
    static let earPath = "M8.9 4.3c2.8 0 4.7 2 4.7 4.8 0 2.5-1.8 3.7-2.9 5.1-.7.9-.9 1.8-.9 2.9 0 1.5-1.2 2.6-2.6 2.6s-2.6-1.2-2.6-2.6c0-1.2.4-2 .4-3.1 0-1.6-1-2.8-1-4.9 0-2.8 2.1-4.8 4.9-4.8z"

    /// The inner curl of the ear.
    static let curlPath = "M8.9 7.4c1.4 0 2.2 1 2.2 2.1 0 1.3-1.1 1.9-1.7 2.8-.4.6-.5 1.2-.5 1.9"

    /// The two arcs of sound arriving at the ear.
    static let wavePaths = [
        "M16.6 10.2a3.6 3.6 0 0 0 0 5.2",
        "M19.9 8.2a6.8 6.8 0 0 0 0 9.2",
    ]

    /// The design box the paths live in, and the weight they are drawn at.
    static let box: CGFloat = 24
    static let stroke: CGFloat = 2

    // MARK: - Variants

    /// How much of the mark to draw.
    ///
    /// The ear is always the mark; what changes is whether sound is arriving
    /// (`idle`), being taken in (`recording` — a filled silhouette, the way SF
    /// Symbols pair `mic` with `mic.fill`), or not being listened for at all
    /// (`processing` is busy, `offline` is struck through).
    enum Variant {
        case idle, recording, processing, offline

        var showsWaves: Bool { self == .idle || self == .recording }
        var isFilled: Bool { self == .recording }
        var isSlashed: Bool { self == .offline }

        var accessibilityDescription: String {
            switch self {
            case .idle: return "SunoFlow — ready"
            case .recording: return "SunoFlow — recording"
            case .processing: return "SunoFlow — transcribing"
            case .offline: return "SunoFlow — speech engine offline"
            }
        }
    }

    // MARK: - Drawing

    /// Draws the mark centred in `rect`, scaled to the shorter side.
    static func draw(_ variant: Variant, in rect: CGRect, color: CGColor, into ctx: CGContext) {
        let scale = min(rect.width, rect.height) / box
        let transform = CGAffineTransform(
            translationX: rect.midX - box * scale / 2,
            y: rect.midY + box * scale / 2
        ).scaledBy(x: scale, y: -scale)   // SVG's y grows downwards; Quartz's grows up.
        let width = stroke * scale

        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)

        let ear = placed(earPath, transform)
        if variant.isFilled {
            // Fill *and* stroke, so the silhouette keeps the same outer edge as
            // the outlined variants and the mark doesn't jump size on record.
            ctx.addPath(ear); ctx.fillPath()
            ctx.addPath(ear); ctx.strokePath()
        } else {
            ctx.addPath(ear); ctx.strokePath()
            ctx.addPath(placed(curlPath, transform)); ctx.strokePath()
        }

        if variant.showsWaves {
            for wave in wavePaths {
                ctx.addPath(placed(wave, transform)); ctx.strokePath()
            }
        }

        if variant.isSlashed {
            let slash = CGMutablePath()
            slash.move(to: CGPoint(x: 4.2, y: 19.8).applying(transform))
            slash.addLine(to: CGPoint(x: 19.8, y: 4.2).applying(transform))
            // Knock a gap out from under the slash first, so it reads as one
            // stroke crossing the mark rather than a line tangled up in it.
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(width * 2.4)
            ctx.addPath(slash); ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(slash); ctx.strokePath()
        }
    }

    /// The mark as a template image, so macOS handles light/dark menu bars and
    /// the pressed-state inversion on its own, and SwiftUI can tint it with
    /// `.foregroundStyle`.
    static func image(_ variant: Variant = .idle, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Inset by half the stroke so round caps aren't clipped at the edge.
            let inset = stroke * (size / box) / 2
            draw(variant, in: rect.insetBy(dx: inset, dy: inset),
                 color: NSColor.black.cgColor, into: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = variant.accessibilityDescription
        return image
    }

    // MARK: - SVG path reading

    /// Parsed once; the mark is fixed at build time.
    private static let parsed: [String: CGPath] = {
        var map: [String: CGPath] = [:]
        for d in [earPath, curlPath] + wavePaths { map[d] = parse(d) }
        return map
    }()

    private static func placed(_ d: String, _ transform: CGAffineTransform) -> CGPath {
        let out = CGMutablePath()
        out.addPath(parsed[d] ?? parse(d), transform: transform)
        return out
    }

    /// A deliberately small SVG path reader: it understands exactly the commands
    /// the mark uses (M, L, C, S, A, Z, and their relative forms). The
    /// alternative is hand-porting the curves into Swift, where they would
    /// quietly drift away from the ones the website ships.
    private static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = PathScanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        while !scanner.isAtEnd {
            if let letter = scanner.takeCommand() { command = letter }
            let relative = command.isLowercase

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.lowercased()) {
            case "m":
                let p = point(scanner.number(), scanner.number())
                path.move(to: p)
                current = p; subpathStart = p; lastControl = nil
                // Extra coordinate pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"

            case "l":
                let p = point(scanner.number(), scanner.number())
                path.addLine(to: p); current = p; lastControl = nil

            case "c":
                let c1 = point(scanner.number(), scanner.number())
                let c2 = point(scanner.number(), scanner.number())
                let end = point(scanner.number(), scanner.number())
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastControl = c2

            case "s":
                // Smooth curve: the first control point mirrors the previous one.
                let previous = lastControl ?? current
                let c1 = CGPoint(x: 2 * current.x - previous.x, y: 2 * current.y - previous.y)
                let c2 = point(scanner.number(), scanner.number())
                let end = point(scanner.number(), scanner.number())
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastControl = c2

            case "a":
                let rx = scanner.number(), ry = scanner.number()
                let rotation = scanner.number()
                let largeArc = scanner.number() != 0, sweep = scanner.number() != 0
                let end = point(scanner.number(), scanner.number())
                addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                       rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = end; lastControl = nil

            case "z":
                path.closeSubpath()
                current = subpathStart; lastControl = nil

            default:
                return path   // An unsupported command: stop rather than guess.
            }
        }
        return path
    }

    /// Endpoint-parameterised elliptical arc to cubic Béziers (SVG spec F.6.5).
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation degrees: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }

        let phi = degrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Grow the radii if they're too small to span the chord (spec F.6.6).
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard length > 0 else { return 0 }
            var a = acos(min(1, max(-1, (ux * vx + uy * vy) / length)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
        let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry
        var theta = angle(1, 0, ux, uy)
        var sweepAngle = angle(ux, uy, vx, vy)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        // A cubic approximates at most a quarter turn well; split beyond that.
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let step = sweepAngle / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var from = p0

        for _ in 0..<segments {
            let next = theta + step
            func on(_ t: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * cos(t) - ry * sinPhi * sin(t),
                        y: cy + rx * sinPhi * cos(t) + ry * cosPhi * sin(t))
            }
            func tangent(_ t: CGFloat) -> CGPoint {
                CGPoint(x: -rx * cosPhi * sin(t) - ry * sinPhi * cos(t),
                        y: -rx * sinPhi * sin(t) + ry * cosPhi * cos(t))
            }
            let end = on(next), d0 = tangent(theta), d1 = tangent(next)
            path.addCurve(to: end,
                          control1: CGPoint(x: from.x + k * d0.x, y: from.y + k * d0.y),
                          control2: CGPoint(x: end.x - k * d1.x, y: end.y - k * d1.y))
            from = end; theta = next
        }
    }
}

/// Character-by-character reader for SVG path data, where numbers may run
/// together without separators (`.4-3.1` is two numbers, `0.4` and `-3.1`).
private struct PathScanner {
    private let characters: [Character]
    private var index = 0

    init(_ string: String) { characters = Array(string) }

    var isAtEnd: Bool {
        var i = index
        while i < characters.count, isSeparator(characters[i]) { i += 1 }
        return i >= characters.count
    }

    private func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "," || c == "\n" || c == "\t" || c == "\r"
    }

    private mutating func skipSeparators() {
        while index < characters.count, isSeparator(characters[index]) { index += 1 }
    }

    /// Consumes and returns a command letter, or nil if the next token is a
    /// number (a repeated coordinate set for the command already in effect).
    mutating func takeCommand() -> Character? {
        skipSeparators()
        guard index < characters.count, characters[index].isLetter else { return nil }
        defer { index += 1 }
        return characters[index]
    }

    mutating func number() -> CGFloat {
        skipSeparators()
        var text = ""
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            text.append(characters[index]); index += 1
        }
        var seenDot = false
        while index < characters.count {
            let c = characters[index]
            if c.isNumber {
                text.append(c); index += 1
            } else if c == "." && !seenDot {
                seenDot = true; text.append(c); index += 1
            } else {
                break
            }
        }
        return CGFloat(Double(text) ?? 0)
    }
}
