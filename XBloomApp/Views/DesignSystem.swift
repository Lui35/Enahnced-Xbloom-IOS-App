import SwiftUI

/// The app's one visual system.
///
/// There used to be two — `AppTheme` on Home, Settings and diagnostics, and
/// `StudioTheme` on every machine screen — with the same background, the same
/// panel, the same accent under different names, and two greens a shade apart
/// both meaning "good". Beans and History drew from both inside a single
/// scroll view. One set of names now, so a colour cannot drift from its
/// meaning.
enum StudioTheme {
    // MARK: Surfaces, darkest first

    /// The ground everything sits on.
    static let background = Color(red: 0.045, green: 0.05, blue: 0.05)
    /// A card lifted off the ground.
    static let panel = Color(red: 0.10, green: 0.12, blue: 0.12)
    /// A control or well inside a card.
    static let raised = Color(red: 0.15, green: 0.18, blue: 0.18)

    // MARK: Meaning

    /// The single interactive tint: anything tappable, selected, or in
    /// progress. Decoration is not its job.
    static let accent = Color(red: 0.63, green: 0.79, blue: 0.80)
    /// The far end of the accent, for the one gradient that carries a recipe's
    /// identity. Two screens had it written out by hand.
    static let accentDeep = Color(red: 0.52, green: 0.70, blue: 0.71)
    /// Done, on target, connected.
    static let mint = Color(red: 0.24, green: 0.82, blue: 0.56)
    /// The warm half of the palette: coffee itself, roast, grind, and heat.
    static let crema = Color(red: 0.84, green: 0.66, blue: 0.43)
    /// The cold half: iced recipes and the ice that goes in them.
    static let iced = Color(red: 0.45, green: 0.80, blue: 0.92)
    /// Off target but usable; the brew still runs.
    static let warning = Color(red: 0.98, green: 0.71, blue: 0.33)
    /// Failed, refused, or destructive.
    static let danger = Color(red: 0.98, green: 0.48, blue: 0.44)
    /// Secondary text and inactive marks. Every value above clears 7:1 on
    /// `background`; this one clears 5:1, which is the floor for body text.
    static let muted = Color.white.opacity(0.52)

    // MARK: Form

    /// Corner radii. Cards hold the largest curve, controls a tighter one, so
    /// nesting reads as depth instead of noise.
    enum Radius {
        static let card: CGFloat = 24
        static let tile: CGFloat = 18
        static let control: CGFloat = 16
        static let chip: CGFloat = 12
    }

    /// Vertical rhythm. Sections breathe at `section`, rows inside a card at
    /// `row`, and lines within a row at `line`.
    enum Space {
        static let section: CGFloat = 22
        static let card: CGFloat = 18
        static let row: CGFloat = 12
        static let line: CGFloat = 6
        /// The screen's own left and right margin.
        static let margin: CGFloat = 18
    }

    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.09, green: 0.13, blue: 0.13), Color(red: 0.12, green: 0.24, blue: 0.24)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// The ground plus a single warm bloom behind the top-trailing corner. One
/// background for the whole app: the previous pair disagreed about the bloom's
/// colour, size and offset, so moving between tabs shifted the light.
struct StudioBackground: View {
    var body: some View {
        StudioTheme.background
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(StudioTheme.accent.opacity(0.10))
                    .frame(width: 320, height: 320)
                    .blur(radius: 70)
                    .offset(x: 130, y: -170)
                    .allowsHitTesting(false)
            }
    }
}

/// A panel with a hairline of its own accent. No shadow: on a ground this dark
/// a black shadow is an effect nobody can see, and the hairline is what
/// actually separates the card from the page.
struct StudioCardModifier: ViewModifier {
    var accent: Color = StudioTheme.accent
    var padding: CGFloat = StudioTheme.Space.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                StudioTheme.panel,
                in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                    .stroke(accent.opacity(0.20), lineWidth: 1)
            }
    }
}

extension View {
    func studioCard(
        accent: Color = StudioTheme.accent,
        padding: CGFloat = StudioTheme.Space.card
    ) -> some View {
        modifier(StudioCardModifier(accent: accent, padding: padding))
    }
}

struct StudioCard<Content: View>: View {
    var accent: Color = StudioTheme.accent
    @ViewBuilder let content: Content

    var body: some View {
        content.studioCard(accent: accent)
    }
}

/// The one section header. `detail` sits on the trailing side for a count or a
/// running figure; `subtitle` sits under the title when the section needs a
/// line of explanation.
struct StudioSectionTitle: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var icon: String?

    var body: some View {
        HStack(alignment: subtitle == nil ? .firstTextBaseline : .top, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudioTheme.accent)
                    .padding(.top, subtitle == nil ? 0 : 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            if let detail {
                Text(detail)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.muted)
                    .padding(.top, subtitle == nil ? 0 : 4)
            }
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color
    var systemImage: String?

    var body: some View {
        Label(title, systemImage: systemImage ?? "circle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = StudioTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            StudioTheme.raised,
            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
        )
    }
}

/// The app's primary button: accent fill, black label, full width.
struct PrimaryActionButtonStyle: ButtonStyle {
    var tint: Color = StudioTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(StudioTheme.background)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(
                tint.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct IconBadge: View {
    let systemImage: String
    var tint: Color = StudioTheme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }
}
