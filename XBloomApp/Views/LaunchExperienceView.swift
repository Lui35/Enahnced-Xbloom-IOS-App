import SwiftUI

/// A short brand reveal, independent of Bluetooth, authentication, and network readiness.
/// The app beneath it starts immediately and remains alive when the reveal finishes.
struct LaunchExperienceView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var isPresented = true
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
                .accessibilityHidden(isPresented)
                .allowsHitTesting(!isPresented)
            if isPresented {
                FirstDropLaunchView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // This is a bounded introduction, never a wait for a machine or the cloud.
            do {
                try await Task.sleep(for: .seconds(reduceMotion || voiceOver ? 0.35 : 1.65))
            } catch { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.35)) {
                isPresented = false
            }
        }
    }
}

private struct FirstDropLaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var dropped = false

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 - 52)
            ZStack {
                StudioTheme.background
                // Low-contrast ornament is deliberately excluded from accessibility.
                ZStack {
                    Circle()
                        .fill(StudioTheme.accent.opacity(0.10))
                        .frame(width: 250, height: 250)
                        .blur(radius: 48)
                    ForEach(0..<3) { index in
                        Circle()
                            .stroke(StudioTheme.accent.opacity(0.08 - Double(index) * 0.018), lineWidth: 1)
                            .frame(width: CGFloat(196 + index * 64), height: CGFloat(196 + index * 64))
                    }
                    Circle()
                        .trim(from: 0, to: revealed ? 0.78 : 0)
                        .stroke(
                            AngularGradient(colors: [.clear, StudioTheme.accent.opacity(0.8)], center: .center),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .frame(width: 164, height: 164)
                        .rotationEffect(.degrees(-140))
                        .opacity(reduceMotion ? 0 : 1)
                        .animation(.easeInOut(duration: 1.15), value: revealed)
                    Image("LaunchMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 118, height: 118)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
                        .scaleEffect(reduceMotion || revealed ? 1 : 0.94)
                        .animation(.spring(response: 0.75, dampingFraction: 0.76), value: revealed)
                }
                .position(center)

                if !reduceMotion {
                    CoffeeDrop()
                        .fill(StudioTheme.accent)
                        .frame(width: 8, height: 13)
                        .offset(y: dropped ? 29 : 0)
                        .opacity(dropped ? 0 : (revealed ? 1 : 0))
                        .position(x: center.x, y: center.y + 83)
                        .animation(.easeIn(duration: 0.38), value: dropped)
                    ForEach(0..<2) { index in
                        Ellipse()
                            .stroke(StudioTheme.accent.opacity(dropped ? 0 : 0.45), lineWidth: 1)
                            .frame(width: 38, height: 10)
                            .scaleEffect(dropped ? CGFloat(2.6 + Double(index) * 0.8) : 0.2)
                            .position(x: center.x, y: center.y + 116)
                            .animation(.easeOut(duration: 0.85).delay(Double(index) * 0.12), value: dropped)
                    }
                }

                VStack(spacing: 12) {
                    Text("xBloom")
                        .font(.system(size: 42, weight: .regular, design: .serif))
                        .foregroundStyle(.white)
                    Text("A little ritual. A better cup.")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                }
                .opacity(revealed ? 1 : 0)
                .offset(y: reduceMotion || revealed ? 0 : 8)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: revealed)
                .position(x: center.x, y: center.y + 190)

                VStack {
                    Spacer()
                    Text("YOUR DAILY RITUAL")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(StudioTheme.muted)
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 24) + 24)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("xBloom")
        .accessibilityIdentifier("launch.brand")
        .task {
            revealed = true
            guard !reduceMotion else { return }
            do { try await Task.sleep(for: .seconds(0.55)) } catch { return }
            dropped = true
        }
    }
}

private struct CoffeeDrop: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.height * 0.55),
                      control2: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.height * 0.55))
        return path
    }
}
