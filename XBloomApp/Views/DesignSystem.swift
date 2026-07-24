import SwiftUI

enum AppTheme {
    static let espresso = Color(red: 0.045, green: 0.05, blue: 0.05)
    static let coffee = Color(red: 0.63, green: 0.79, blue: 0.80)
    static let crema = Color(red: 0.84, green: 0.66, blue: 0.43)
    static let sage = Color(red: 0.32, green: 0.72, blue: 0.57)
    static let canvas = Color(red: 0.045, green: 0.05, blue: 0.05)
    static let card = Color(red: 0.10, green: 0.12, blue: 0.12)

    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.09, green: 0.13, blue: 0.13), Color(red: 0.12, green: 0.24, blue: 0.24)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AppBackground: View {
    var body: some View {
        AppTheme.canvas
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(AppTheme.crema.opacity(0.10))
                    .frame(width: 260, height: 260)
                    .blur(radius: 45)
                    .offset(x: 100, y: -110)
                    .allowsHitTesting(false)
            }
    }
}

struct AppCardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppTheme.coffee.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
    }
}

extension View {
    func appCard(padding: CGFloat = 18) -> some View {
        modifier(AppCardModifier(padding: padding))
    }
}

struct AppSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
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
    var tint: Color = AppTheme.coffee

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
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.coffee

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct IconBadge: View {
    let systemImage: String
    var tint: Color = AppTheme.coffee
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }
}
