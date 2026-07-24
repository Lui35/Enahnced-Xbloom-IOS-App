import ActivityKit
import SwiftUI
import WidgetKit
import XBloomCore

struct XBloomBrewLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BrewActivityAttributes.self) { context in
            LockScreenBrewView(context: context)
                .activityBackgroundTint(Color(red: 0.055, green: 0.065, blue: 0.065))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StageGlyph(phase: context.state.phase, size: 34)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int((context.state.progress * 100).rounded()))%")
                            .font(.title3.bold().monospacedDigit())
                        Text(timeText(context.state.remainingSeconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.stageTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.recipeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBrewDetails(context: context)
                }
            } compactLeading: {
                StageGlyph(phase: context.state.phase, size: 22)
            } compactTrailing: {
                compactTrailing(context.state)
            } minimal: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.03, context.state.progress))
                        .stroke(phaseColor(context.state.phase), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: stageSymbol(context.state.phase))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(phaseColor(context.state.phase))
                }
                .frame(width: 24, height: 24)
            }
            .widgetURL(URL(string: "xbloom://live-brew"))
            .keylineTint(phaseColor(context.state.phase))
        }
    }

    @ViewBuilder
    private func compactTrailing(_ state: BrewActivityAttributes.ContentState) -> some View {
        if state.phase == .grinding {
            Text("GRIND")
                .font(.caption2.bold())
                .foregroundStyle(phaseColor(state.phase))
        } else if state.phase == .complete {
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(phaseColor(state.phase))
        } else {
            Text(state.currentPour > 0 ? "P\(state.currentPour)/\(state.totalPours)" : "\(Int(state.progress * 100))%")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(phaseColor(state.phase))
        }
    }
}

private struct LockScreenBrewView: View {
    let context: ActivityViewContext<BrewActivityAttributes>

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 11) {
                StageGlyph(phase: context.state.phase, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.stageTitle)
                        .font(.headline.bold())
                    Text(context.attributes.recipeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int((context.state.progress * 100).rounded()))%")
                        .font(.title2.bold().monospacedDigit())
                    Text(context.attributes.machineName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ProgressBar(value: context.state.progress, phase: context.state.phase)

            HStack {
                Metric(icon: "drop.fill", value: "\(Int(context.state.waterML.rounded()))", unit: "/ \(context.state.targetWaterML) ml")
                Spacer()
                Metric(icon: "scalemass.fill", value: String(format: "%.1f", context.state.coffeeWeight), unit: "g")
                Spacer()
                Metric(
                    icon: "timer",
                    value: context.state.phase == .complete ? timeText(context.state.elapsedSeconds) : timeText(context.state.remainingSeconds),
                    unit: context.state.phase == .complete ? "total" : "left"
                )
            }
        }
        .padding(16)
    }
}

private struct ExpandedBrewDetails: View {
    let context: ActivityViewContext<BrewActivityAttributes>

    var body: some View {
        VStack(spacing: 9) {
            ProgressBar(value: context.state.progress, phase: context.state.phase)
            HStack {
                Metric(icon: "drop.fill", value: "\(Int(context.state.waterML.rounded()))", unit: "ml")
                Spacer()
                if context.state.currentPour > 0 {
                    Metric(icon: "list.number", value: "\(context.state.currentPour)", unit: "of \(context.state.totalPours)")
                    Spacer()
                }
                Metric(icon: "scalemass.fill", value: String(format: "%.1f", context.state.coffeeWeight), unit: "g")
                Spacer()
                Metric(
                    icon: "thermometer.medium",
                    value: context.state.temperature.map { "\(Int($0.rounded()))°" } ?? "—",
                    unit: "water"
                )
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct StageGlyph: View {
    let phase: BrewProgramPhase
    let size: CGFloat

    var body: some View {
        Image(systemName: stageSymbol(phase))
            .font(.system(size: size * 0.43, weight: .bold))
            .foregroundStyle(phaseColor(phase))
            .frame(width: size, height: size)
            .background(phaseColor(phase).opacity(0.16), in: Circle())
    }
}

private struct Metric: View {
    let icon: String
    let value: String
    let unit: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(Color(red: 0.50, green: 0.84, blue: 0.81))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption.bold().monospacedDigit())
                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProgressBar: View {
    let value: Double
    let phase: BrewProgramPhase

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [phaseColor(phase).opacity(0.65), phaseColor(phase)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(1, max(0.025, value)))
            }
        }
        .frame(height: 7)
    }
}

private func stageSymbol(_ phase: BrewProgramPhase) -> String {
    switch phase {
    case .preparing: "cup.and.saucer.fill"
    case .grinding: "gearshape.2.fill"
    case .heating: "flame.fill"
    case .blooming: "drop.circle.fill"
    case .pouring: "water.waves"
    case .resting: "pause.fill"
    case .complete: "checkmark"
    case .error: "exclamationmark.triangle.fill"
    }
}

private func phaseColor(_ phase: BrewProgramPhase) -> Color {
    switch phase {
    case .preparing: Color(red: 0.70, green: 0.73, blue: 0.72)
    case .grinding: Color(red: 0.84, green: 0.65, blue: 0.43)
    case .heating: .orange
    case .blooming, .pouring: Color(red: 0.50, green: 0.84, blue: 0.81)
    case .resting: Color(red: 0.54, green: 0.69, blue: 0.91)
    case .complete: Color(red: 0.39, green: 0.87, blue: 0.65)
    case .error: .red
    }
}

private func timeText(_ seconds: Int) -> String {
    let safe = max(0, seconds)
    return String(format: "%d:%02d", safe / 60, safe % 60)
}
