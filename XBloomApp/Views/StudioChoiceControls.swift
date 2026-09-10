import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
#endif

struct StudioChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(selected ? StudioTheme.accent : StudioTheme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct StudioFlavorGoalChip: View {
    let goal: RecipeFlavorGoal
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(goal.rawValue, systemImage: selected ? "checkmark.circle.fill" : goal.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selected ? StudioTheme.accent : StudioTheme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

extension RecipeFlavorGoal {
    var icon: String {
        switch self {
        case .balanced: "circle.lefthalf.filled"
        case .sweetness: "heart.fill"
        case .roundness: "circle.fill"
        case .clarity: "sparkle.magnifyingglass"
        case .floral: "camera.macro"
        case .juicy: "drop.fill"
        case .fullBody: "square.fill"
        case .chocolate: "cube.fill"
        case .brightAcidity: "sun.max.fill"
        case .lowAcidity: "minus.circle.fill"
        case .teaLike: "leaf.fill"
        case .cleanFinish: "wind"
        }
    }
}

struct StudioMenuField: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    var icon = "slider.horizontal.3"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if selection == option {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(selection.isEmpty ? "Choose \(title.lowercased())" : selection)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(StudioTheme.accent)
                }
                .foregroundStyle(.white)
                .padding(15)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

struct RoastLevelSelector: View {
    @Binding var selection: String

    private let levels = ["Light", "Medium-light", "Medium", "Medium-dark", "Dark"]
    private let colors: [Color] = [
        Color(red: 0.76, green: 0.53, blue: 0.31),
        Color(red: 0.63, green: 0.39, blue: 0.21),
        Color(red: 0.49, green: 0.28, blue: 0.15),
        Color(red: 0.34, green: 0.19, blue: 0.12),
        Color(red: 0.20, green: 0.12, blue: 0.09),
    ]

    private var selectedIndex: Int {
        levels.firstIndex { $0.caseInsensitiveCompare(selection) == .orderedSame } ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Roast level", systemImage: "flame.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                Spacer()
                Text(levels[selectedIndex])
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudioTheme.crema)
            }
            HStack {
                ForEach(levels.indices, id: \.self) { index in
                    Button {
                        selection = levels[index]
                    } label: {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(colors[index])
                                .frame(width: index == selectedIndex ? 34 : 28, height: index == selectedIndex ? 34 : 28)
                                .overlay {
                                    Circle()
                                        .stroke(index == selectedIndex ? Color.white : .clear, lineWidth: 3)
                                }
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(index == selectedIndex ? .white : StudioTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("1 is light and bright · 5 is dark and developed")
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
        }
        .padding(15)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
    }
}

struct AcidityLevelSelector: View {
    @Binding var level: Int?

    private let names = ["Low", "Soft", "Balanced", "Bright", "Vibrant"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Acidity", systemImage: "sun.max.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                Spacer()
                Text(level.map { names[min(4, max(0, $0 - 1))] } ?? "Unknown")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(level == nil ? StudioTheme.muted : acidityColor)
            }

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        level = value
                    } label: {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(value <= (level ?? 0) ? acidityColor : StudioTheme.panel)
                                .frame(width: value == level ? 34 : 28, height: value == level ? 34 : 28)
                                .overlay {
                                    Circle()
                                        .stroke(value == level ? Color.white : acidityColor.opacity(0.36), lineWidth: value == level ? 3 : 1.5)
                                }
                            Text("\(value)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(value == level ? .white : StudioTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                level = nil
            } label: {
                Label(
                    "Unknown / not provided",
                    systemImage: level == nil ? "checkmark.circle.fill" : "questionmark.circle"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(level == nil ? .black : .white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(level == nil ? StudioTheme.accent : StudioTheme.panel, in: Capsule())
            }
            .buttonStyle(.plain)

            Text("1 is mellow · 3 is balanced · 5 is lively and vibrant")
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
        }
        .padding(15)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
        .sensoryFeedback(.selection, trigger: level ?? 0)
    }

    private var acidityColor: Color {
        switch level ?? 3 {
        case 1: Color(red: 0.64, green: 0.70, blue: 0.47)
        case 2: Color(red: 0.72, green: 0.76, blue: 0.39)
        case 3: Color(red: 0.83, green: 0.75, blue: 0.31)
        case 4: Color(red: 0.91, green: 0.64, blue: 0.27)
        default: Color(red: 0.96, green: 0.49, blue: 0.25)
        }
    }
}

struct StudioSaveBar: View {
    let title: String
    var subtitle: String?
    var enabled = true
    var compact = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            Button(action: action) {
                Text(title)
                    .font(compact ? .subheadline.weight(.bold) : .headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: subtitle == nil ? .infinity : nil)
                    .padding(.horizontal, compact ? 22 : 32)
                    .padding(.vertical, compact ? 11 : 16)
                    .background(StudioTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.42)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}
