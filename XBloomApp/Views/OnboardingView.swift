import SwiftUI

struct OnboardingView: View {
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(SupabaseService.self) private var cloud
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var page = 0
    @State private var accountReturnPage = 3
    var isGuide = false
    let onComplete: () -> Void

    private let titles = ["Your coffee, your way.", "Meet your machine.", "From bean to first sip.", "A little better, every brew.", "Your studio awaits."]
    private let chapters = ["THE POSSIBILITIES", "THE CONNECTION", "THE FIRST CUP", "THE EVERYDAY RITUAL", "YOUR ACCOUNT"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if page < 4 {
                        OnboardingArtwork(page: page)
                            .frame(height: dynamicType.isAccessibilitySize ? 160 : 208)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(chapters[page])
                            .font(.caption.weight(.bold)).tracking(2)
                            .foregroundStyle(StudioTheme.accent)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        Text(titles[page])
                            .font(.largeTitle.weight(.semibold)).fontDesign(.serif)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("onboarding.title")
                        Text(subtitle)
                            .font(.subheadline).foregroundStyle(StudioTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    pageContent
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, page == 4 ? 20 : 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .id(page)
            footer
        }
        .background(StudioTheme.background.ignoresSafeArea())
        .tint(StudioTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: cloud.isAuthenticated) { _, authenticated in
            if authenticated && page == 4 && !isGuide { onComplete() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page > 0 {
                Button { move(to: page == 4 ? accountReturnPage : page - 1) } label: {
                    Image(systemName: "arrow.left").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(StudioTheme.panel, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Back")
            } else {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(StudioTheme.accent).font(.title3)
                    .frame(width: 36, height: 44).accessibilityHidden(true)
            }
            Text("xBloom").font(.headline)
            Spacer(minLength: 0)
            if isGuide {
                Button("Done", action: onComplete).frame(minWidth: 44, minHeight: 44)
            } else if page < 4 {
                Button("Skip tour") { move(to: 4) }
                    .font(.subheadline.weight(.medium)).foregroundStyle(StudioTheme.muted)
                    .frame(minHeight: 44)
            } else {
                Label("Optional", systemImage: "person.crop.circle")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
        }
        .frame(maxWidth: 520).frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(StudioTheme.background)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private var footer: some View {
        if page < 4 {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(0..<4) { index in
                            Capsule().fill(index == page ? StudioTheme.accent : StudioTheme.raised)
                                .frame(width: index == page ? 24 : 6, height: 6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tour step \(page + 1) of 4")
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: page)
                    Spacer()
                    Text("\(page + 1) / 4")
                        .font(.caption.monospacedDigit()).foregroundStyle(StudioTheme.muted)
                        .accessibilityHidden(true)
                }
                Button { move(to: page + 1) } label: {
                    HStack {
                        Text(page == 3 ? "Make yourself at home" : "Continue")
                        Spacer()
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                }
                .buttonStyle(WelcomePrimaryButton())
                .accessibilityIdentifier("onboarding.continue")
            }
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(StudioTheme.background)
        } else {
            VStack(spacing: 0) {
                Rectangle().fill(StudioTheme.line).frame(height: 1)
                Button(cloud.isAuthenticated ? "Start using xBloom" : "Use without an account", action: onComplete)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(StudioTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("onboarding.finish")
                if !cloud.isAuthenticated && !dynamicType.isAccessibilitySize {
                    Text("Your machine. Your recipes. No sign-in needed.")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                        .multilineTextAlignment(.center).padding(.bottom, 10)
                }
            }
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
            .padding(.horizontal, 24).background(StudioTheme.background)
        }
    }

    private var subtitle: String {
        switch page {
        case 0: "A more personal companion for your xBloom Studio."
        case 1: "A nearby machine. A Bluetooth connection. You’re in."
        case 2: "Start with a recipe. Make it yours as you go."
        case 3: "Keep what works. Explore what’s next."
        default: "Sign in to bring your coffee library with you."
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0:
            VStack(spacing: 20) {
                feature("slider.horizontal.3", "Dial in every detail", "Dose, grind, temperature, flow, and every pour.")
                feature("leaf", "Keep your coffee together", "Beans, favorite recipes, and the story of each cup.")
                feature("scalemass", "Go beyond the brew", "A live scale, grinder controls, and manual pouring.")
            }
            Text("Built for xBloom Studio · Independent companion app")
                .font(.caption).foregroundStyle(StudioTheme.muted)
        case 1:
            VStack(spacing: 20) {
                step(1, "Wake your Studio", "Keep the machine on and your iPhone nearby.")
                step(2, "Allow Bluetooth", "Turn on Bluetooth and allow access when iOS asks. Close the official xBloom app first.")
                step(3, "We’ll remember it", "The app reconnects on launch. You can always retry from Home.")
            }
            Button { machine.connect() } label: {
                HStack(spacing: 10) {
                    if isConnecting { ProgressView().tint(StudioTheme.accent) }
                    else { Image(systemName: machine.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right").accessibilityHidden(true) }
                    Text(connectionLabel)
                    Spacer(minLength: 0)
                    if !isConnecting && !machine.isConnected { Image(systemName: "arrow.up.right").accessibilityHidden(true) }
                }
                .font(.subheadline.weight(.semibold)).padding(16).frame(minHeight: 52)
                .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(StudioTheme.accent.opacity(0.4)) }
            }
            .buttonStyle(.plain).disabled(machine.isConnected || isConnecting)
            if let error = machine.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(StudioTheme.warning)
            } else {
                Text("No machine nearby? You can connect later.")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
        case 2:
            VStack(spacing: 20) {
                step(1, "Pick your recipe", "Open Recipes to explore, edit, or preview a brew without the machine.")
                step(2, "Get the setup ready", "Fill the tank. Place your cup, dripper, and filter. Weigh your dose, then load the beans.")
                step(3, "Brew, taste, remember", "Tap Start brew and confirm the setup. Follow the pours, then rate your cup in History.")
            }
            Label("Using pre-ground coffee? Turn the grinder off in your recipe.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(StudioTheme.muted)
        case 3:
            VStack(spacing: 20) {
                feature("square.and.arrow.up", "Pass along a good cup", "Share a recipe link from its menu. Anyone with xBloom can save a copy.")
                feature("wrench.and.screwdriver", "Care for your Studio", "Find cleaning and service reminders in Settings → Maintenance.")
            }
            AccountBenefitsView()
        default:
            if cloud.isAuthenticated {
                Label("You’re signed in. Welcome to your studio.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(StudioTheme.mint).studioCard()
                AccountBenefitsView()
            } else {
                AccountAccessView(compactBenefits: true)
            }
        }
    }

    private var isConnecting: Bool { [.scanning, .connecting, .subscribing].contains(machine.connectionState) }
    private var connectionLabel: String {
        switch machine.connectionState {
        case .connected: "Machine connected"
        case .scanning: "Searching for your machine…"
        case .connecting, .subscribing: "Connecting…"
        default: "Connect my machine"
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title3).foregroundStyle(StudioTheme.accent)
                .frame(width: 36, height: 36).accessibilityHidden(true)
            rowText(title, detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number.formatted()).font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.accent).frame(width: 32, height: 32)
                .background(StudioTheme.accent.opacity(0.1), in: Circle())
            rowText(title, detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func rowText(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(StudioTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func move(to page: Int) {
        // Keep controls stable while changing chapters; animate the progress
        // indicator only, so outgoing screens never overlap the next form.
        if page == 4 && self.page < 4 { accountReturnPage = self.page }
        self.page = page
    }
}

struct WelcomePrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).foregroundStyle(StudioTheme.background)
            .padding(.horizontal, 20).padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(StudioTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45), in: RoundedRectangle(cornerRadius: 16))
    }
}
