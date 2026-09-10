import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
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
