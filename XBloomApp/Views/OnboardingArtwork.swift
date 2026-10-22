import SwiftUI

/// Decorative vector scenes keep the tour lightweight and crisp at every size.
struct OnboardingArtwork: View {
    let page: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(StudioTheme.accent.opacity(0.055))
                Circle().stroke(StudioTheme.accent.opacity(0.10), lineWidth: 1)
                    .frame(width: 220, height: 220).offset(x: 50, y: 25)
                Circle().stroke(StudioTheme.accent.opacity(0.07), lineWidth: 1)
                    .frame(width: 290, height: 290).offset(x: 50, y: 25)
                scene
                    .scaleEffect(min(geometry.size.width / 342, geometry.size.height / 208))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
    }

    @ViewBuilder private var scene: some View {
        switch page {
        case 1:
            ZStack {
                machine.offset(x: 62, y: -3)
                phone.offset(x: -88, y: 12)
                Image(systemName: "link").font(.title3.weight(.semibold))
                    .foregroundStyle(StudioTheme.mint).frame(width: 42, height: 42)
                    .background(StudioTheme.background, in: Circle())
                    .overlay { Circle().stroke(StudioTheme.mint.opacity(0.3)) }
                    .offset(x: -6, y: 8)
            }
        case 3:
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(StudioTheme.panel)
                    .frame(width: 198, height: 142)
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(StudioTheme.line) }
                    .rotationEffect(.degrees(-7)).offset(x: -34, y: 6)
                VStack(alignment: .leading, spacing: 16) {
                    Label("A BETTER NEXT CUP", systemImage: "sparkles")
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(StudioTheme.accent)
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(0..<5) { index in
                            Capsule().fill(index == 4 ? StudioTheme.accent : StudioTheme.accent.opacity(0.24))
                                .frame(width: 15, height: [30.0, 46, 40, 60, 72][index])
                        }
                    }
                }.offset(x: -34)
                VStack(spacing: 8) {
                    Image(systemName: "leaf").font(.system(size: 28, weight: .light))
                    Text("YOUR COFFEE").font(.system(size: 8, weight: .bold)).tracking(1)
                }
                .foregroundStyle(StudioTheme.background).frame(width: 92, height: 116)
                .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                .rotationEffect(.degrees(9)).offset(x: 91, y: 18)
            }
        default:
            ZStack {
                machine.offset(x: 38, y: -3)
                VStack(alignment: .leading, spacing: 8) {
                    Text(page == 2 ? "FIRST POUR" : "YOUR RECIPE")
                        .font(.system(size: 9, weight: .bold)).tracking(1.5)
                        .foregroundStyle(StudioTheme.muted)
                    Text(page == 2 ? "50 ml" : "18 g")
                        .font(.system(size: 26, weight: .medium, design: .serif))
                        .foregroundStyle(StudioTheme.accent)
                    Text(page == 2 ? "Bloom, then breathe." : "A little more you.")
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                    HStack(spacing: 4) {
                        ForEach(0..<5) { index in
                            Capsule().fill(index < 2 ? StudioTheme.accent : StudioTheme.raised)
                                .frame(width: 12, height: 3)
                        }
                    }
                }
                .padding(14)
                .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(StudioTheme.line) }
                .rotationEffect(.degrees(-5)).offset(x: -82, y: 32)
            }
        }
    }

    private var machine: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [StudioTheme.raised, StudioTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 132, height: 170)
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(StudioTheme.muted.opacity(0.25)) }
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(StudioTheme.mint).frame(width: 4, height: 4)
                    Text("STUDIO").font(.system(size: 8, weight: .bold)).tracking(2)
                        .foregroundStyle(StudioTheme.muted)
                }
                .frame(width: 90, height: 26)
                .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 8))
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(StudioTheme.background)
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2).fill(StudioTheme.muted).frame(width: 28, height: 5)
                        Rectangle().fill(StudioTheme.accent.opacity(0.65)).frame(width: 2, height: 26)
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 38, weight: .light)).foregroundStyle(StudioTheme.accent)
                    }
                }.frame(width: 90, height: 83)
                HStack(spacing: 10) {
                    ForEach(0..<3) { _ in Circle().strokeBorder(StudioTheme.muted.opacity(0.4)).frame(width: 14, height: 14) }
                }
            }
        }
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 18).fill(StudioTheme.background).frame(width: 72, height: 126)
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.muted.opacity(0.5), lineWidth: 2) }
            .overlay {
                VStack(spacing: 12) {
                    Capsule().fill(StudioTheme.raised).frame(width: 24, height: 4)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 25)).foregroundStyle(StudioTheme.mint)
                    Text("CONNECTED").font(.system(size: 6, weight: .bold)).tracking(0.8).foregroundStyle(StudioTheme.muted)
                }
            }.rotationEffect(.degrees(-8))
    }
}
