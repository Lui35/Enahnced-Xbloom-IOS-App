import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
#endif

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
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
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
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
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
    var height: CGFloat = 92
    /// An optional label that changes with the value — what the current setting
    /// actually means, shown inside the box next to the number.
    var caption: String?

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
            RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                .fill(StudioTheme.panel)

            GeometryReader { proxy in
                // The fill has to be measured inside the inset, not outside it.
                // Sizing it to the full width and then padding made the laid-out
                // width the fill plus both insets, so a maxed-out bar hung ten
                // points past the box it sits in.
                let inset: CGFloat = 5
                let available = max(0, proxy.size.width - inset * 2)
                let clamped = min(1, max(0, progress))

                RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
                    .fill(tint.opacity(0.17))
                    .frame(width: min(available, max(8, available * clamped)))
                    .padding(inset)
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
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .contentTransition(.opacity)
                            .animation(.snappy(duration: 0.18), value: caption)
                    }
                    Spacer(minLength: 4)
                    Text(prefix + formattedValue)
                        .font(.system(size: height > 86 ? 34 : 29, weight: .semibold, design: .rounded))
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
            .padding(14)
        }
        .frame(height: height)
        // A second guarantee that nothing inside can paint past the border,
        // whatever a future value or animation does.
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                .stroke(tint.opacity(0.85), lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
        .overlay {
            GeometryReader { proxy in
                HorizontalPanSurface(
                    onBegan: {
                        dragStart = value
                    },
                    onChanged: { translation in
                        guard let start = dragStart else { return }
                        let usableWidth = max(1, Double(proxy.size.width))
                        let span = range.upperBound - range.lowerBound
                        let raw = start + (Double(translation) / usableWidth) * span
                        setValue(raw)
                    },
                    onEnded: {
                        dragStart = nil
                    }
                )
            }
        }
        .sensoryFeedback(
            .impact(weight: .medium, intensity: 0.9),
            trigger: hapticTick
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            [
                "\(prefix)\(formattedValue) \(unit)",
                caption,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
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

#if canImport(UIKit)
/// A horizontal-only pan surface that fails before recognition when the user
/// moves vertically. Unlike a SwiftUI DragGesture that merely ignores vertical
/// values after recognizing them, this hands the touch directly to the parent
/// ScrollView so the page can scroll from anywhere on a dial.
private struct HorizontalPanSurface: UIViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: HorizontalPanSurface

        init(surface: HorizontalPanSurface) {
            self.surface = surface
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                surface.onBegan()
            case .changed:
                surface.onChanged(recognizer.translation(in: recognizer.view).x)
            case .ended, .cancelled, .failed:
                surface.onEnded()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.12
        }
    }
}
#endif

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
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
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

struct PourPatternSelector: View {
    @Binding var selection: PourPattern

    private let patterns: [PourPattern] = [.center, .spiral, .circular]

    var body: some View {
        GeometryReader { proxy in
            let outerPadding: CGFloat = 6
            let segmentWidth = (proxy.size.width - outerPadding * 2) / CGFloat(patterns.count)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                    .fill(StudioTheme.raised)

                HStack(spacing: 8) {
                    PourPatternMark(
                        pattern: selection,
                        color: .black.opacity(0.78),
                        size: 31
                    )
                    Text(title(for: selection))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                    .frame(width: segmentWidth, height: proxy.size.height - outerPadding * 2)
                    .background(
                        StudioTheme.accent,
                        in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
                    )
                    .frame(width: segmentWidth)
                    .offset(
                        x: outerPadding + CGFloat(selectedIndex) * segmentWidth
                    )
                    .animation(.smooth(duration: 0.24), value: selectedIndex)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    ForEach(patterns, id: \.self) { pattern in
                        Button {
                            selection = pattern
                        } label: {
                            PourPatternMark(
                                pattern: pattern,
                                color: StudioTheme.accent,
                                size: 34
                            )
                            .opacity(selection == pattern ? 0 : 1)
                            .frame(width: segmentWidth, height: proxy.size.height)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title(for: pattern)) pour")
                        .accessibilityValue(selection == pattern ? "Selected" : "Not selected")
                    }
                }
                .padding(.horizontal, outerPadding)
                // Every button keeps exactly the same layout regardless of the
                // selection. Only the independent pill above is animated.
                .animation(nil, value: selection)
            }
        }
        .frame(height: 82)
        .accessibilityElement(children: .contain)
    }

    private var selectedIndex: Int {
        patterns.firstIndex(of: selection) ?? 0
    }

    private func title(for pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Center"
        case .circular: "Circular"
        case .spiral: "Spiral"
        }
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

struct AIProcessingOverlay: View {
    let title: String
    let messages: [String]
    var systemImage = "sparkles"
    var tint = StudioTheme.accent
    var onCancel: (() -> Void)?

    @State private var rotates = false
    @State private var breathes = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 9)
                        .frame(width: 112, height: 112)

                    Circle()
                        .trim(from: 0.05, to: 0.72)
                        .stroke(
                            AngularGradient(
                                colors: [tint.opacity(0.18), tint, StudioTheme.mint, tint.opacity(0.18)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .frame(width: 112, height: 112)
                        .rotationEffect(.degrees(rotates ? 360 : 0))

                    Circle()
                        .trim(from: 0.12, to: 0.48)
                        .stroke(tint.opacity(0.46), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 86, height: 86)
                        .rotationEffect(.degrees(rotates ? -360 : 0))

                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == 1 ? StudioTheme.mint : tint)
                            .frame(width: index == 1 ? 8 : 6, height: index == 1 ? 8 : 6)
                            .offset(y: -56)
                            .rotationEffect(.degrees(Double(index) * 120 + (rotates ? 360 : 0)))
                    }

                    Image(systemName: systemImage)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.78))
                        .frame(width: 62, height: 62)
                        .background(
                            RadialGradient(
                                colors: [Color.white.opacity(0.92), tint],
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: 48
                            ),
                            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                        )
                        .scaleEffect(breathes ? 1.04 : 0.94)
                        .shadow(color: tint.opacity(0.38), radius: breathes ? 22 : 9)
                }

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)

                    TimelineView(.periodic(from: .now, by: 1.6)) { context in
                        let message = messages.isEmpty
                            ? "Working with Gemini…"
                            : messages[
                                Int(context.date.timeIntervalSinceReferenceDate / 1.6)
                                    % messages.count
                            ]
                        Text(message)
                            .id(message)
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.muted)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(minHeight: 40)
                            .transition(.blurReplace)
                    }
                }

                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index == 1 ? StudioTheme.mint : tint)
                            .frame(width: breathes == (index != 1) ? 18 : 7, height: 7)
                            .opacity(breathes == (index == 2) ? 0.45 : 1)
                    }
                }
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathes)

                if let onCancel {
                    Button("Cancel request", action: onCancel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.06), in: Capsule())
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 290)
            .padding(.horizontal, 24)
            .padding(.vertical, 26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        }
        .onAppear {
            withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
                rotates = true
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                breathes = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). Gemini is processing your request.")
        .transition(.opacity)
        .zIndex(100)
    }
}
