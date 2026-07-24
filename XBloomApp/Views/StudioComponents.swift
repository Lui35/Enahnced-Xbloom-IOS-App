import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
#endif

enum StudioTheme {
    static let background = Color(red: 0.045, green: 0.05, blue: 0.05)
    static let panel = Color(red: 0.10, green: 0.12, blue: 0.12)
    static let raised = Color(red: 0.15, green: 0.18, blue: 0.18)
    static let accent = Color(red: 0.63, green: 0.79, blue: 0.80)
    static let mint = Color(red: 0.24, green: 0.82, blue: 0.56)
    static let muted = Color.white.opacity(0.52)
}

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

struct StudioCard<Content: View>: View {
    var accent: Color = StudioTheme.accent
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
            }
    }
}

struct StudioSectionTitle: View {
    let title: String
    var detail: String?
    var icon: String?

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudioTheme.accent)
            }
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StudioTheme.muted)
            }
        }
    }
}

struct StudioTextField: View {
    let title: String
    @Binding var text: String
    var icon: String?
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon ?? "circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            TextField(title, text: $text, axis: axis)
                .font(.body.weight(.medium))
                .textFieldStyle(.plain)
                .padding(14)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}

struct StudioValueStepper: View {
    let title: String
    let value: String
    let icon: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            HStack {
                Text(value)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    stepButton("minus", action: decrement)
                    stepButton("plus", action: increment)
                }
            }
        }
        .padding(14)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct StudioDialBox: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var prefix = ""
    var unit = ""
    var decimals = 0
    var tint = StudioTheme.accent
    var height: CGFloat = 104

    @State private var dragStart: Double?
    @State private var hapticTick = 0

    private var progress: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private var formattedValue: String {
        String(format: "%.\(decimals)f", value)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(StudioTheme.panel)

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.17))
                    .frame(width: max(8, proxy.size.width * min(1, max(0, progress))))
                    .padding(5)
                    .animation(.linear(duration: 0.06), value: value)
            }
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                    Spacer()
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint.opacity(0.7))
                }
                Spacer(minLength: 0)
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Spacer()
                    Text(prefix + formattedValue)
                        .font(.system(size: height > 90 ? 38 : 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: height)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.85), lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { gesture in
                    guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                    let start = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    // A full-width drag covers the complete value range. Using the
                    // gesture's relative translation prevents the value jumping to
                    // the touch location when a scrub begins.
                    let usableWidth = max(1, Double(UIScreen.main.bounds.width - 36))
                    let span = range.upperBound - range.lowerBound
                    let raw = start + (Double(gesture.translation.width) / usableWidth) * span
                    setValue(raw)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: hapticTick)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(prefix)\(formattedValue) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                setValue(value + step)
            case .decrement:
                setValue(value - step)
            @unknown default:
                break
            }
        }
    }

    private func setValue(_ raw: Double) {
        let stepped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
        let next = min(range.upperBound, max(range.lowerBound, stepped))
        guard abs(next - value) > step / 100 else { return }
        value = next
        hapticTick &+= 1
    }
}

struct GrinderPowerControl: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label("Grinder", systemImage: "gearshape.2.fill")
                .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 3) {
                stateButton(title: "ON", value: true)
                stateButton(title: "OFF", value: false)
            }
            .padding(4)
            .background(Color.black.opacity(0.30), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sensoryFeedback(.selection, trigger: isOn)
    }

    private func stateButton(title: String, value: Bool) -> some View {
        Button {
            withAnimation(.snappy) { isOn = value }
        } label: {
            Text(title)
                .font(.caption.weight(.heavy))
            .foregroundStyle(isOn == value ? .black : .white.opacity(0.58))
            .frame(width: 52)
            .padding(.vertical, 8)
            .background(
                isOn == value ? (value ? StudioTheme.accent : Color.white.opacity(0.72)) : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grinder \(title)")
        .accessibilityValue(isOn == value ? "Selected" : "Not selected")
    }
}

struct PourPatternMark: View {
    let pattern: PourPattern
    var color: Color = StudioTheme.accent
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            switch pattern {
            case .center:
                Circle()
                    .stroke(color.opacity(0.34), lineWidth: max(1.5, size * 0.07))
                    .frame(width: size * 0.72, height: size * 0.72)
                Circle()
                    .stroke(color.opacity(0.68), lineWidth: max(1.5, size * 0.07))
                    .frame(width: size * 0.42, height: size * 0.42)
                Circle()
                    .fill(color)
                    .frame(width: size * 0.16, height: size * 0.16)
            case .circular:
                Circle()
                    .stroke(color.opacity(0.22), lineWidth: max(1.5, size * 0.055))
                    .frame(width: size * 0.70, height: size * 0.70)
                CircularPourShape()
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: max(2, size * 0.085),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: size * 0.82, height: size * 0.82)
            case .spiral:
                SpiralShape()
                    .stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.085), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.78, height: size * 0.78)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A clean clockwise ring with an integrated arrowhead. Drawing the head as
/// part of the same path avoids the detached "random dot" appearance that a
/// separate SF Symbol produced at compact preview sizes.
private struct CircularPourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.34
        let start = Angle.degrees(-68)
        let end = Angle.degrees(242)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )

        let angle = CGFloat(end.radians)
        let tip = CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
        let tangent = CGVector(dx: -sin(angle), dy: cos(angle))
        let normal = CGVector(dx: -tangent.dy, dy: tangent.dx)
        let headLength = min(rect.width, rect.height) * 0.19
        let headWidth = min(rect.width, rect.height) * 0.10
        let base = CGPoint(
            x: tip.x - tangent.dx * headLength,
            y: tip.y - tangent.dy * headLength
        )
        path.move(to: CGPoint(x: base.x + normal.dx * headWidth, y: base.y + normal.dy * headWidth))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: base.x - normal.dx * headWidth, y: base.y - normal.dy * headWidth))
        return path
    }
}

private struct SpiralShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let turns = 2.35
        let points = 64
        for index in 0...points {
            let fraction = CGFloat(index) / CGFloat(points)
            let angle = fraction * turns * 2 * .pi
            let radius = fraction * min(rect.width, rect.height) * 0.48
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct AgitationMark: View {
    var active = true
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .stroke(active ? StudioTheme.mint.opacity(0.42) : StudioTheme.muted.opacity(0.25), lineWidth: 2)
            Image(systemName: "water.waves")
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(active ? StudioTheme.mint : StudioTheme.muted)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum AgitationPhase {
    case before
    case after

    var title: String {
        switch self {
        case .before: "Before"
        case .after: "After"
        }
    }
}

/// A compact visual sentence. "Before" reads agitation → pour, while "after"
/// reads pour → agitation, so the timing remains understandable without a
/// long label inside a small square.
struct AgitationPhaseMark: View {
    let phase: AgitationPhase
    var active = true
    var size: CGFloat = 28

    private var color: Color {
        active ? StudioTheme.mint : StudioTheme.muted
    }

    var body: some View {
        HStack(spacing: max(1, size * 0.06)) {
            if phase == .before {
                AgitationMark(active: active, size: size)
                directionArrow
                pourDrop
            } else {
                pourDrop
                directionArrow
                AgitationMark(active: active, size: size)
            }
        }
        .frame(width: size * 2.12, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agitation \(phase.title.lowercased())")
        .accessibilityValue(active ? "On" : "Off")
    }

    private var directionArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: size * 0.29, weight: .heavy))
            .foregroundStyle(color)
    }

    private var pourDrop: some View {
        Image(systemName: "drop.fill")
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size * 0.48)
    }
}

struct AgitationTimingMarks: View {
    let before: Bool
    let after: Bool
    var size: CGFloat = 24
    var showInactive = false

    var body: some View {
        HStack(spacing: 4) {
            if before || showInactive {
                AgitationPhaseMark(phase: .before, active: before, size: size)
            }
            if after || showInactive {
                AgitationPhaseMark(phase: .after, active: after, size: size)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            StudioTheme.mint.opacity((before || after) ? 0.09 : 0.035),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
    }
}

struct PourFeatureBadge: View {
    let title: String
    let icon: AnyView
    var active = true

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(active ? .white.opacity(0.84) : StudioTheme.muted)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white.opacity(active ? 0.08 : 0.04), in: Capsule())
    }
}

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
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
                    .foregroundStyle(AppTheme.crema)
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
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
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
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
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
