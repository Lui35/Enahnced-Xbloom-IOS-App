import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
#endif

struct AIProcessingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let messages: [String]
    var systemImage = "sparkles"
    var tint = StudioTheme.accent
    var onCancel: (() -> Void)?
    /// Leaves the screen without stopping the work. Only offered where the
    /// request outlives the view that started it — this overlay covers the
    /// whole screen, navigation bar included, so without it the only way out
    /// of a running request is to kill it.
    var leaveTitle: String?
    var onLeave: (() -> Void)?

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
                                colors: [tint.opacity(0.18), tint, tint, tint.opacity(0.18)],
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
                            .fill(index == 1 ? tint : tint)
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
                        // Fixed radius on purpose. Animating a shadow radius
                        // re-rasterizes the blur every frame; the scale above
                        // already carries the breath.
                        .shadow(color: tint.opacity(0.38), radius: 14)
                }

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)

                    TimelineView(.periodic(from: .now, by: 1.6)) { context in
                        let message = messages.isEmpty
                            ? "Working with Gemini…"
                            : messages[
                                (reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 1.6))
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
                            .fill(index == 1 ? tint : tint)
                            .frame(width: breathes == (index != 1) ? 18 : 7, height: 7)
                            .opacity(breathes == (index == 2) ? 0.45 : 1)
                    }
                }
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathes)

                if let onLeave {
                    Button(leaveTitle ?? "Leave it running", action: onLeave)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(tint, in: Capsule())
                        .buttonStyle(.plain)
                }

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
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
                rotates = true
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                breathes = true
            }
        }
        .accessibilityElement(children: .contain)
        .transition(.opacity)
        .zIndex(100)
    }
}

/// A card for work the AI is still doing, shown in the list where its result
/// will land.
///
/// Motion is driven by `TimelineView(.animation)` rather than by `withAnimation`
/// on a `@State` flag: a repeating animation started in `onAppear` is dropped
/// whenever the surrounding list re-renders — which, in a screen fed by live
/// queries, is constantly. That is why the first version sat still.
struct AIGeneratingCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var contentHeight: CGFloat = 128
    let title: String
    let subtitle: String
    var icon = "wand.and.sparkles"
    var tint = StudioTheme.accent
    /// Skeletons standing in for the figures the finished card will show.
    var placeholderCount = 3
    var onCancel: (() -> Void)?

    private let shape = RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let turn = Angle.degrees(time.truncatingRemainder(dividingBy: 3) / 3 * 360)
            // A second, slower rotation keeps the glow from looking welded to
            // the border it travels along.
            let inner = Angle.degrees(-time.truncatingRemainder(dividingBy: 4.5) / 4.5 * 360)
            let pulse = 0.5 + 0.5 * sin(time * 2)

            content(inner: inner, pulse: pulse)
                .background(StudioTheme.panel, in: shape)
                .overlay {
                    // The travelling light itself: one hard stroke for the
                    // edge, one blurred copy under it for the glow.
                    ZStack {
                        shape.stroke(border, lineWidth: 9).blur(radius: 13)
                        shape.stroke(border, lineWidth: 4).blur(radius: 4).opacity(0.9)
                        shape.stroke(border, lineWidth: 2)
                    }
                    .rotationEffect(turn)
                    // Wide enough for the bloom to spread; a tight mask cropped
                    // the glow back to the same width as the line itself.
                    .mask(shape.stroke(lineWidth: 18))
                    .allowsHitTesting(false)
                }
                .clipShape(shape)
        }
    }

    /// A conic sweep with one bright arc in it. Rotating the whole gradient
    /// walks that arc around the card.
    private var border: AngularGradient {
        AngularGradient(
            colors: [
                tint.opacity(0.05),
                tint.opacity(0.05),
                tint,
                tint,
                tint.opacity(0.05),
                tint.opacity(0.05),
            ],
            center: .center
        )
    }

    private func content(inner: Angle, pulse: Double) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 3.5)
                    .frame(width: 74, height: 74)
                Circle()
                    .trim(from: 0.06, to: 0.7)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.1), tint, tint], center: .center),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .frame(width: 74, height: 74)
                    .rotationEffect(inner)
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                    .scaleEffect(0.94 + 0.06 * pulse)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(2, reservesSpace: true)

                HStack(spacing: 8) {
                    ForEach(0..<placeholderCount, id: \.self) { index in
                        Capsule()
                            .fill(StudioTheme.raised)
                            .frame(width: 46, height: 9)
                            // The shimmer runs along the row rather than each
                            // pill blinking on its own.
                            .opacity(0.55 + 0.45 * abs(sin(pulse * .pi + Double(index) * 0.7)))
                    }
                }
            }

            Spacer(minLength: 0)

            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                        .frame(width: 44, height: 44)
                        .background(StudioTheme.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
        }
        .frame(minHeight: contentHeight)
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

extension AnyTransition {
    static var popIn: AnyTransition { .opacity }
}
