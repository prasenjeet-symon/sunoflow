import AppKit
import SwiftUI

// MARK: - Design tokens

/// The dashboard's design system — one place for colour, spacing, radii, type
/// and motion, so every surface in the window reads as the same product.
///
/// The brand gradient deliberately mirrors the dictation overlay's violet→pink
/// waveform (see `DictationOverlay`), so the floating bubble and the dashboard
/// feel like two views of one app rather than two apps.
enum Theme {

    // MARK: Brand

    static let violet = Color(red: 0.545, green: 0.486, blue: 1.000)
    static let indigo = Color(red: 0.404, green: 0.416, blue: 0.980)
    static let pink   = Color(red: 1.000, green: 0.561, blue: 0.816)

    static let brand = LinearGradient(
        colors: [violet, pink],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// A washed-out brand fill for selected rows and tinted panels, where a
    /// full-strength gradient would fight with the text sitting on top of it.
    static let brandWash = LinearGradient(
        colors: [violet.opacity(0.20), pink.opacity(0.14)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: Semantic status

    static let success = Color(red: 0.16, green: 0.76, blue: 0.50)
    static let warning = Color(red: 0.98, green: 0.67, blue: 0.22)
    static let danger  = Color(red: 0.98, green: 0.38, blue: 0.42)

    static func status(_ ok: Bool) -> Color { ok ? success : danger }

    static func gradient(for color: Color) -> LinearGradient {
        LinearGradient(
            colors: [color, color.opacity(0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: Surfaces

    /// The page behind the cards.
    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    /// The cards themselves — one step up from the canvas in both appearances.
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    /// Inset wells inside a card (rows, code blocks, list items).
    static var well: Color { Color.primary.opacity(0.045) }
    static var hairline: Color { Color.primary.opacity(0.08) }

    /// The soft top-down sheen that keeps large cards from looking flat.
    static let sheen = LinearGradient(
        colors: [Color.white.opacity(0.07), Color.white.opacity(0.0)],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: Spacing

    enum Space {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let xl: CGFloat = 30
        static let xxl: CGFloat = 40

        /// Padding inside a card, and the gap between stacked cards.
        static let card: CGFloat = 20
        static let cardGap: CGFloat = 18
        /// Padding around the whole content column.
        static let page: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let well: CGFloat = 9
    }

    // MARK: Motion

    /// The default for anything that moves position or size — settles quickly
    /// with just enough overshoot to feel physical.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// A softer spring for content swapping in, which shouldn't bounce.
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.95)
    /// Hover and press feedback — fast enough to feel instant.
    static let quick = Animation.easeOut(duration: 0.16)
}

// MARK: - Type scale

extension Font {
    /// Page titles. Rounded, because it pairs with the app's soft, friendly icon set.
    static let sunoDisplay = Font.system(size: 25, weight: .bold, design: .rounded)
    static let sunoTitle = Font.system(size: 16, weight: .semibold, design: .rounded)
    /// Card and section headings.
    static let sunoHeadline = Font.system(size: 15, weight: .semibold, design: .rounded)
    /// Sub-headings inside a card (status card titles, list group labels).
    static let sunoSubhead = Font.system(size: 13.5, weight: .semibold, design: .rounded)
    static let sunoBody = Font.system(size: 13, weight: .regular)
    static let sunoBodyMedium = Font.system(size: 13, weight: .medium)
    static let sunoCaption = Font.system(size: 11.5, weight: .regular)
    static let sunoCaptionMedium = Font.system(size: 11.5, weight: .medium)
    static let sunoMicro = Font.system(size: 10.5, weight: .medium)
    static let sunoMono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

// MARK: - Materials

/// A live blurred backdrop. Used for the sidebar so the desktop tint bleeds
/// through the way it does in Finder and Mail.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}

// MARK: - Surface modifiers

extension View {
    /// The standard card treatment: surface fill, a top sheen, a hairline
    /// border and a soft shadow that lifts a little on hover.
    func sunoSurface(
        radius: CGFloat = Theme.Radius.card,
        hovering: Bool = false,
        interactive: Bool = false
    ) -> some View {
        background(
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.sheen)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        hovering ? Theme.violet.opacity(0.32) : Theme.hairline,
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(hovering && interactive ? 0.16 : 0.09),
                radius: hovering && interactive ? 20 : 12,
                x: 0, y: hovering && interactive ? 9 : 5
            )
        )
    }

    /// A quieter inset well for rows nested inside a card.
    func sunoWell(radius: CGFloat = Theme.Radius.well, tint: Color? = nil) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint?.opacity(0.10) ?? Theme.well)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(tint?.opacity(0.22) ?? Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Card

/// The primary content container. Everything in a section lives in one of these.
struct SunoCard<Content: View>: View {
    var spacing: CGFloat = 14
    var padding: CGFloat = Theme.Space.card
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunoSurface(hovering: hovering)
        .animation(Theme.quick, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A card that leads with an icon chip, a title and a one-line explanation —
/// the pattern used by every settings section.
struct SunoSection<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    var tint: LinearGradient = Theme.brand
    @ViewBuilder var content: () -> Content

    var body: some View {
        SunoCard(spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                IconChip(systemImage: systemImage, gradient: tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.sunoHeadline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.sunoCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            content()
        }
    }
}

// MARK: - Small components

/// A rounded-square glyph tile. The dashboard's main unit of colour.
struct IconChip: View {
    let systemImage: String
    var gradient: LinearGradient = Theme.brand
    var size: CGFloat = 36
    var glowColor: Color = Theme.violet

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(gradient)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: glowColor.opacity(0.35), radius: 8, x: 0, y: 3)
    }
}

/// A status dot that breathes a halo while it's live, so "online" reads at a
/// glance without needing to parse the label next to it.
struct PulseDot: View {
    var color: Color
    var active: Bool = true
    var size: CGFloat = 8

    @State private var animating = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.40))
                    .scaleEffect(animating ? 1.0 : 0.35)
                    .opacity(animating ? 0.0 : 0.85)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(active ? 0.6 : 0), radius: 4)
        }
        .frame(width: size * 2.6, height: size * 2.6)
        .onAppear { restart() }
        .onChange(of: active) { _ in restart() }
    }

    private func restart() {
        animating = false
        guard active else { return }
        withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) {
            animating = true
        }
    }
}

/// A tinted capsule for short status words.
struct SunoBadge: View {
    let text: String
    var color: Color = Theme.violet
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.sunoMicro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.26), lineWidth: 1))
    }
}

/// A gradient-filled progress track, used for the model download.
struct SunoProgressBar: View {
    var value: Double
    var total: Double
    var height: CGFloat = 7

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Theme.brand)
                    .frame(width: max(height, geo.size.width * fraction))
                    .shadow(color: Theme.violet.opacity(0.45), radius: 5, y: 1)
            }
        }
        .frame(height: height)
        .animation(Theme.gentle, value: fraction)
    }
}

/// A label/value line, used for the setup summary and the About section.
struct SunoInfoRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var valueColor: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label)
                .font(.sunoCaption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.sunoCaptionMedium)
                .foregroundStyle(valueColor ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .sunoWell()
    }
}

/// An inline advisory banner — used for permissions and offline warnings.
struct SunoNotice: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var color: Color = Theme.warning

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.sunoCaption)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunoWell(radius: Theme.Radius.control, tint: color)
    }
}

// MARK: - Button styles

/// The filled, brand-gradient call to action. One per screen, at most.
struct SunoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Theme.brand)
                    .shadow(color: Theme.violet.opacity(isEnabled ? 0.40 : 0), radius: 10, y: 4)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// The neutral companion to the primary style.
struct SunoSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
            .animation(Theme.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A borderless text action for tertiary things ("Reset", "View logs").
struct SunoGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var color: Color = Theme.violet
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(hovering ? 0.12 : 0))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
            .animation(Theme.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A compact square icon button for row-level actions (edit, delete).
struct SunoIconButtonStyle: ButtonStyle {
    var color: Color = .secondary
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(hovering ? color : Color.secondary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(hovering ? 0.14 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
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
    static func sunoIcon(_ color: Color = .secondary) -> SunoIconButtonStyle { .init(color: color) }
}
