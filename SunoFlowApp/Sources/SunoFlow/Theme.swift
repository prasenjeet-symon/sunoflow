import AppKit
import SwiftUI

// MARK: - Design tokens

/// The dashboard's design system.
///
/// The dashboard is one flat sheet of paper. There are no cards, no boxes, no
/// nested panels and no drop shadows: structure comes from hairline rules,
/// generous vertical rhythm, and rows that run the full width of the column so
/// nothing is left floating in dead space.
///
/// Colour is rationed. Ink for text, one accent for selection and the single
/// primary action per screen, and three semantic colours for status. Everything
/// else is paper.
enum Theme {

    // MARK: Surfaces

    /// The content sheet.
    static let paper = Color(nsColor: .sunoPaper)
    /// The navigation column — a half-step warmer so the eye can tell them
    /// apart without needing a border between them.
    static let shell = Color(nsColor: .sunoShell)
    /// A barely-there fill for inputs and pressed states.
    static let wash  = Color(nsColor: .sunoWash)

    /// The hairline between rows.
    static let rule       = Color(nsColor: .sunoRule)
    /// The heavier hairline that closes a section or the page header.
    static let ruleStrong = Color(nsColor: .sunoRuleStrong)

    // MARK: Ink

    static let ink   = Color(nsColor: .sunoInk)
    /// Ink, one step lighter — the hover state of the single filled action.
    static let inkRaised = Color(nsColor: .sunoInkRaised)
    /// Surface-fill ink (the filled primary action, the recording disc): stays
    /// near-black in both modes. See `NSColor.sunoInkFill`.
    static let inkFill       = Color(nsColor: .sunoInkFill)
    static let inkFillRaised = Color(nsColor: .sunoInkFillRaised)
    static let body  = Color(nsColor: .sunoBody)
    static let faint = Color(nsColor: .sunoFaint)

    // MARK: Accent

    static let accent     = Color(nsColor: .sunoAccent)
    static let accentSoft = Color(nsColor: .sunoAccentSoft)

    // MARK: Semantic status

    static let success = Color(nsColor: .sunoSuccess)
    static let warning = Color(nsColor: .sunoWarning)
    static let danger  = Color(nsColor: .sunoDanger)

    static func status(_ ok: Bool) -> Color { ok ? success : danger }

    // MARK: Metrics

    enum Space {
        /// Left and right margin of the content column.
        static let page: CGFloat = 40
        /// Space above a section's label.
        static let section: CGFloat = 34
        /// Vertical padding inside a single row.
        static let row: CGFloat = 15
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    // MARK: Motion

    static let spring = Animation.spring(response: 0.30, dampingFraction: 0.95)
    static let gentle = Animation.easeOut(duration: 0.20)
    static let quick  = Animation.easeOut(duration: 0.13)
}

// MARK: - AppKit mirrors

/// The floating panels are drawn by hand in AppKit rather than composed in
/// SwiftUI, so the same tokens have to exist as `NSColor`s. Each one is derived
/// from the `Theme` value above rather than re-typed from the hex, so the sheet
/// and the panels can never drift apart.
extension NSColor {
    /// Builds an `NSColor` that resolves to `light` in light mode and `dark`
    /// in dark mode, following the window's effective appearance. Stored as a
    /// _dynamic_ color (not a fixed value), so AppKit resolves the right
    /// variant automatically for text, layers, and `applySunoPaper` alike.
    static func sunoDynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(sunoHex: dark) : NSColor(sunoHex: light)
        }
    }

    /// The single source of truth for the palette. Each token is declared once
    /// here as a light/dark hex pair; the SwiftUI `Theme` values above and every
    /// AppKit surface resolve through them, so the sheet and the panels can
    /// never drift apart or forget to cover a mode.
    convenience init(sunoHex: UInt32) {
        let r = CGFloat((sunoHex >> 16) & 0xFF) / 255
        let g = CGFloat((sunoHex >> 8) & 0xFF) / 255
        let b = CGFloat(sunoHex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static let sunoPaper      = sunoDynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let sunoShell      = sunoDynamic(light: 0xF8F7F4, dark: 0x232326)
    static let sunoWash       = sunoDynamic(light: 0xF6F5F2, dark: 0x26262A)
    static let sunoRule       = sunoDynamic(light: 0xECEAE6, dark: 0x333338)
    static let sunoRuleStrong = sunoDynamic(light: 0xE2DFDA, dark: 0x3F3F46)
    static let sunoInk        = sunoDynamic(light: 0x17171B, dark: 0xF2F2F4)
    static let sunoInkRaised  = sunoDynamic(light: 0x29292F, dark: 0xE6E6EA)
    static let sunoBody        = sunoDynamic(light: 0x5A5A65, dark: 0xAFAFB8)
    static let sunoFaint       = sunoDynamic(light: 0x8C8C96, dark: 0x8A8A94)
    static let sunoAccent      = sunoDynamic(light: 0x4F49B5, dark: 0x7B75D8)
    static let sunoAccentSoft  = sunoDynamic(light: 0xF1F0FA, dark: 0x2A2640)
    static let sunoSuccess     = sunoDynamic(light: 0x167A54, dark: 0x42A57C)
    static let sunoWarning     = sunoDynamic(light: 0x9C6410, dark: 0xD9A455)
    static let sunoDanger      = sunoDynamic(light: 0xA83A30, dark: 0xE06B5C)

    /// Surface-fill ink (the filled primary button, the recording disc): stays
    /// near-black in BOTH modes so a dark shape against dark paper never loses
    /// its silhouette. Not dynamic by design.
    static let sunoInkFill       = NSColor(sunoHex: 0x17171B)
    static let sunoInkFillRaised = NSColor(sunoHex: 0x29292F)
}

extension NSView {
    /// Paints a floating surface as a sheet of paper: the fill, the hairline
    /// that gives it an edge, and the one lift this design permits.
    ///
    /// The sheet itself has no shadows, because it is all one plane. A panel
    /// floating over someone else's window genuinely is on another plane, and
    /// white paper over a white document would otherwise have no edge at all.
    /// So the panels — and only the panels — get the smallest shadow that
    /// separates them, with the hairline border still doing the real work.
    ///
    /// Note the `shadow` assignment. AppKit syncs a layer-backed view's
    /// `shadow` — nil by default — onto its backing layer as it displays, which
    /// silently wipes any shadow set on the layer alone. Handing the view a
    /// shadow object first is what makes the lift stick.
    func applySunoPaper(cornerRadius: CGFloat, lift: CGFloat) {
        wantsLayer = true
        shadow = NSShadow()
        guard let layer = layer else { return }
        layer.backgroundColor = NSColor.sunoPaper.cgColor
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 1
        layer.borderColor = NSColor.sunoRuleStrong.cgColor
        layer.shadowColor = NSColor.sunoInkFill.cgColor
        layer.shadowOpacity = 0.13
        layer.shadowRadius = lift
        layer.shadowOffset = CGSize(width: 0, height: -lift / 3.5)
    }
}

extension Theme {
    /// `Theme.spring` for Core Animation, which is parameterised by stiffness
    /// and damping instead of response and damping fraction:
    /// `stiffness = (2π / response)²`, `damping = 2 · fraction · √stiffness`.
    /// Same curve, same restraint — a settle, not a bounce.
    enum Spring {
        static let mass: CGFloat = 1
        static let stiffness: CGFloat = 438  // response 0.30
        static let damping: CGFloat = 40     // dampingFraction 0.95
    }

    /// The `Animation` tokens' durations for Core Animation (`Animation` in
    /// SwiftUI carries its duration privately — mirror the numbers here).
    enum Timing {
        static let gentle: CFTimeInterval = 0.20
        static let quick: CFTimeInterval = 0.13
    }
}

// MARK: - Type scale

extension Font {
    /// The page title. Large, tight, and the only display size in the app.
    static let sunoDisplay  = Font.system(size: 27, weight: .semibold)
    /// A statement line — the one sentence that answers "am I set up?".
    static let sunoLead     = Font.system(size: 19, weight: .semibold)
    static let sunoRowTitle = Font.system(size: 13.5, weight: .medium)
    static let sunoValue    = Font.system(size: 13, weight: .medium)
    static let sunoBody     = Font.system(size: 13, weight: .regular)
    static let sunoCaption  = Font.system(size: 12, weight: .regular)
    static let sunoKicker   = Font.system(size: 10.5, weight: .semibold)
    static let sunoMono     = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

// MARK: - Rules

/// The hairline that does all the structural work in this design.
struct Rule: View {
    var strong: Bool = false
    var body: some View {
        Rectangle()
            .fill(strong ? Theme.ruleStrong : Theme.rule)
            .frame(height: 1)
    }
}

// MARK: - Section label

/// The small capitalised label that opens a group of rows. It replaces what
/// used to be a card header — same job, none of the chrome.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased())
                .font(.sunoKicker)
                .tracking(0.8)
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.sunoCaption)
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.top, Theme.Space.section)
        .padding(.bottom, 9)
    }
}

// MARK: - Rows

/// Set on a group of rows where *some* rows carry a leading glyph. Rows without
/// one then reserve the same space, so every title in the group shares a left
/// edge instead of stepping in and out.
private struct RowIconColumnKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var sunoRowIconColumn: Bool {
        get { self[RowIconColumnKey.self] }
        set { self[RowIconColumnKey.self] = newValue }
    }
}

extension View {
    func rowIconColumn(_ enabled: Bool = true) -> some View {
        environment(\.sunoRowIconColumn, enabled)
    }
}

/// The workhorse. A full-width line: an optional glyph, a title with an
/// optional explanation beneath it, and whatever control belongs on the right.
///
/// Rows draw their own bottom hairline so a run of them reads as one table;
/// pass `divider: false` on the last row of a group.
struct SunoRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var iconColor: Color = Theme.faint
    var divider: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.sunoRowIconColumn) private var iconColumn

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 13) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 17)
                } else if iconColumn {
                    Color.clear.frame(width: 17, height: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.sunoRowTitle)
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.sunoCaption)
                            .foregroundStyle(Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                trailing()
            }
            .padding(.vertical, Theme.Space.row)

            if divider { Rule() }
        }
    }
}

extension SunoRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil,
         iconColor: Color = Theme.faint, divider: Bool = true) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage,
                  iconColor: iconColor, divider: divider) { EmptyView() }
    }
}

/// A label on the left, a value hard right. Used for read-only summaries.
struct ValueRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var valueColor: Color? = nil
    var mono: Bool = false
    var divider: Bool = true

    var body: some View {
        SunoRow(title: label, systemImage: systemImage, divider: divider) {
            Text(value)
                .font(mono ? .sunoMono : .sunoValue)
                .foregroundStyle(valueColor ?? Theme.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Status

/// A status word with a dot. No capsule, no border — on a flat sheet the colour
/// and the dot are enough.
struct StatusText: View {
    let text: String
    var color: Color = Theme.success
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
            Text(text)
                .font(.sunoValue)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

/// An inline advisory line. Tinted text and a glyph, sitting directly on the
/// page rather than inside a coloured box.
struct SunoNotice: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var color: Color = Theme.warning

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1.5)
            Text(text)
                .font(.sunoCaption)
                .foregroundStyle(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A flat progress track for the model download.
struct SunoProgressBar: View {
    var value: Double
    var total: Double
    var height: CGFloat = 4

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ruleStrong)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(Theme.gentle, value: fraction)
    }
}

// MARK: - Button styles

/// The one filled action per screen: solid ink, like the website.
struct SunoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(hovering ? Theme.inkFillRaised : Theme.inkFill)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.32)
            .animation(Theme.quick, value: configuration.isPressed)
            .animation(Theme.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// The neutral action: a soft fill, no border.
struct SunoSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(hovering ? Theme.ruleStrong.opacity(0.7) : Theme.wash))
            .opacity(isEnabled ? 1 : 0.35)
            .animation(Theme.quick, value: configuration.isPressed)
            .animation(Theme.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A text action for tertiary things ("Reset", "Clear all").
struct SunoGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var color: Color = Theme.accent
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(color)
            .opacity(isEnabled ? (hovering ? 0.7 : 1) : 0.35)
            .animation(Theme.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A compact icon button for row-level actions.
struct SunoIconButtonStyle: ButtonStyle {
    var color: Color = Theme.faint
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(hovering ? color : Theme.faint.opacity(0.75))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .animation(Theme.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == SunoPrimaryButtonStyle {
    static var sunoPrimary: SunoPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == SunoSecondaryButtonStyle {
    static var sunoSecondary: SunoSecondaryButtonStyle { .init() }
}
extension ButtonStyle where Self == SunoGhostButtonStyle {
    static var sunoGhost: SunoGhostButtonStyle { .init() }
    static func sunoGhost(_ color: Color) -> SunoGhostButtonStyle { .init(color: color) }
}
extension ButtonStyle where Self == SunoIconButtonStyle {
    static func sunoIcon(_ color: Color = Theme.faint) -> SunoIconButtonStyle { .init(color: color) }
}

// MARK: - Field styling

/// Text fields on a flat sheet: a soft well, no border, no focus ring fight.
struct SunoFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.sunoBody)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.wash))
    }
}
