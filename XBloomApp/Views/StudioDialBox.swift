import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
#endif

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
    /// Where the machine physically is, when that is a different thing from
    /// what the dial is set to. Drawn as a second, grey fill that travels to
    /// the setting while the machine catches up.
    var machineValue: Double?

    @State private var dragStart: Double?
    @State private var hapticTick = 0

    private var progress: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The machine's own position on the same 0–1 scale as `progress`.
    private var machineProgress: Double? {
        guard let machineValue, range.upperBound > range.lowerBound else { return nil }
        let fraction = (machineValue - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(1, max(0, fraction))
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

                if let machineProgress {
                    // Over the tinted fill, not under it: the machine is
                    // usually behind the setting, and a grey bar hidden beneath
                    // the fill would show nothing at all while it travelled.
                    RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
                        .fill(StudioTheme.muted.opacity(0.22))
                        .frame(width: min(available, max(3, available * machineProgress)))
                        .padding(inset)
                        // Slow enough to read as travel. The machine steps one
                        // unit every ~200 ms, so this joins the steps up.
                        .animation(.easeInOut(duration: 0.28), value: machineProgress)
                }
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
                machineValue.map { String(format: "machine at %.0f", $0) },
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
