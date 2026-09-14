import SwiftUI

/// Original studio layout, with warm amber accents and neutral slate surfaces.
enum StudioTheme {
    static let background = Color(red: 0.12, green: 0.135, blue: 0.15)
    static let panel = Color(red: 0.185, green: 0.205, blue: 0.225)
    static let raised = Color(red: 0.245, green: 0.265, blue: 0.29)
    static let line = Color.white.opacity(0.10)
    static let accent = Color(red: 0.98, green: 0.78, blue: 0.56)
    static let mint = Color(red: 0.48, green: 0.76, blue: 0.62)
    static let crema = Color(red: 0.88, green: 0.72, blue: 0.53)
    static let hot = Color(red: 1.0, green: 0.57, blue: 0.49)
    static let iced = Color(red: 0.57, green: 0.75, blue: 0.86)
    static let warning = Color(red: 0.94, green: 0.73, blue: 0.43)
    static let danger = Color(red: 0.96, green: 0.53, blue: 0.49)
    static let muted = Color(red: 0.74, green: 0.77, blue: 0.80)

    enum Radius {
        static let card: CGFloat = 22
        static let tile: CGFloat = 16
        static let control: CGFloat = 14
        static let chip: CGFloat = 10
    }
    enum Space {
        static let section: CGFloat = 22
        static let card: CGFloat = 18
        static let row: CGFloat = 12
        static let line: CGFloat = 6
        static let margin: CGFloat = 18
    }

}

/// Flat surfaces keep the familiar controls legible without a decorative glow.
struct StudioBackground: View {
    var body: some View { StudioTheme.background.ignoresSafeArea() }
}

/// Neutral panel borders keep accent color on controls and meaningful status.

struct StudioCardModifier: ViewModifier {
    var accent: Color? = nil
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
                    .strokeBorder(accent?.opacity(0.20) ?? StudioTheme.line, lineWidth: 1)
            }
    }
}

extension View {
    func studioCard(
        accent: Color? = nil,
        padding: CGFloat = StudioTheme.Space.card
    ) -> some View {
        modifier(StudioCardModifier(accent: accent, padding: padding))
    }
}

struct StudioCard<Content: View>: View {
    var accent: Color? = nil
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
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
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
