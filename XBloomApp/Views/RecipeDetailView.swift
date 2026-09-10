import SwiftData
import SwiftUI
import XBloomCore

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var brewSession
    @Query private var beans: [StoredBean]
    let stored: StoredRecipe
    @State var recipe: Recipe
    @State private var editing: Recipe?
    @State private var errorMessage: String?
    @State private var weighingDose = false

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                VStack(spacing: 18) {
                    HStack { Spacer(); FavoriteRecipeButton(stored: stored) }
                    detailIdentity
                    coffeeSummary
                    pourOverview
                    aiInsight
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Menu {
                    Button("Edit recipe", systemImage: "pencil") { editing = recipe }
                    Button("Preview without the machine", systemImage: "play.rectangle.on.rectangle") {
                        brewSession.present(recipe: recipe, mode: .simulation)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.bold))
                        .frame(width: 54, height: 54)
                        .background(StudioTheme.raised, in: Circle())
                }
                .buttonStyle(.plain)

                if machine.isConnected {
                    // Weighing is only worth offering when the machine is going
                    // to grind. With the grinder off the coffee is already
                    // ground and measured, and the beans never touch the scale.
                    if recipe.useGrinder {
                        brewAction(
                            "Weigh dose",
                            icon: "scalemass.fill",
                            tint: StudioTheme.mint
                        ) {
                            weighingDose = true
                        }
                    }
                    brewAction("Start brew", icon: "play.fill", tint: StudioTheme.accent) {
                        brewSession.present(recipe: recipe, mode: .live)
                    }
                } else {
                    // One action while offline: two buttons that both just
                    // connect say nothing about the choice waiting behind them.
                    brewAction("Connect to brew", icon: "bolt.fill", tint: StudioTheme.accent) {
                        machine.connect()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .padding(.top, 10)
            .background(.ultraThinMaterial)
        }
        .alert("Brew error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editing) { value in
            RecipeEditorView(recipe: value) { updated in
                recipe = updated
                stored.update(with: updated)
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $weighingDose) {
            DoseWeighingView(recipe: recipe) { measuredDose in
                // The weighed amount replaces the recipe's target for this brew
                // only. It is what the machine is told, what history records,
                // and what comes off the bean bag — the saved recipe keeps its
                // own dose.
                var brewed = recipe
                brewed.dose = measuredDose
                brewSession.present(recipe: brewed, mode: .live)
            }
        }
        .onChange(of: stored.payload) { _, _ in
            if let updated = stored.recipe { recipe = updated }
        }
        .preferredColorScheme(.dark)
    }

    private func brewAction(
        _ title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(machine.isSendingRecipe)
    }

    private var detailIdentity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                // The name leads. An all-caps "HOT POUR-OVER" used to sit above
                // it as a kicker, and a 52pt ghost "3 POURS" sat beside it,
                // both repeating what the figures and the Pours section say.
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(recipe.name)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        if recipe.generatedByAI {
                            Label("AI", systemImage: "sparkles")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.12), in: Capsule())
                        }
                    }
                    Text([recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.black.opacity(0.56))
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 8) {
                Text("1:\(String(format: "%.1f", recipe.ratio))")
                heroDivider
                Text("\(recipe.totalWater) ml")
                heroDivider
                Label(
                    recipe.brewStyle == .iced ? "Iced" : "Hot",
                    systemImage: recipe.brewStyle == .iced ? "snowflake" : "sun.max.fill"
                )
                if recipe.brewStyle == .iced, recipe.iceGrams > 0 {
                    heroDivider
                    Label("\(recipe.iceGrams) g ice", systemImage: "snowflake")
                        .foregroundStyle(.black.opacity(0.56))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.black.opacity(0.76))
        .padding(StudioTheme.Space.card)
        .background(
            LinearGradient(colors: [StudioTheme.accent, StudioTheme.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
        )
        .padding(.top, 8)
    }

    private var bean: BeanProfile? {
        // ponytail: linear scan over the bean library — a handful of bags.
        recipe.beanID.flatMap { id in beans.first { $0.id == id }?.profile }
    }

    /// How many cups of this recipe are left in the bag, as a caption on the
    /// dose it qualifies.
    ///
    /// The dose sheet needs a connected machine, so a bag that cannot cover the
    /// recipe used to be discovered after committing to a brew. The bag is
    /// known here, and one glyph plus a count is enough to carry it — a short
    /// bag turns the caption red and names the grams instead of the cups.
    private var bagCaption: (text: String, icon: String, tint: Color)? {
        guard let bean else { return nil }
        let cups = Int(floor(bean.remainingWeightGrams / max(1, recipe.dose)))
        guard cups >= 1 else {
            return (
                String(format: "%.0f g left", bean.remainingWeightGrams),
                "exclamationmark.triangle.fill",
                StudioTheme.danger
            )
        }
        return (cups == 1 ? "1 cup left" : "\(cups) cups left", "cup.and.saucer.fill", StudioTheme.muted)
    }

    private var heroDivider: some View {
        Rectangle()
            .fill(.black.opacity(0.28))
            .frame(width: 1, height: 26)
    }

    private var coffeeSummary: some View {
        HStack(spacing: 0) {
            compactMetric(
                "Dose",
                "\(String(format: "%.1f", recipe.dose)) g",
                caption: bagCaption?.text,
                captionIcon: bagCaption?.icon,
                captionTint: bagCaption?.tint ?? StudioTheme.muted
            )
            summaryDivider
            compactMetric(
                "Grind",
                recipe.useGrinder ? "\(recipe.grindSize)" : "Off",
                caption: recipe.useGrinder ? GrindSizeGuide.method(for: recipe.grindSize) : nil
            )
            summaryDivider
            compactMetric("RPM", recipe.useGrinder ? "\(recipe.rpm.rawValue)" : "—")
        }
        .padding(.vertical, 13)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var pourOverview: some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 18) {
                StudioSectionTitle(
                    title: "Pours",
                    detail: "\(recipe.pours.count) steps · \(recipe.totalWater) ml",
                    icon: "drop.fill"
                )

                GeometryReader { proxy in
                    let spacing: CGFloat = 6
                    let count = max(1, recipe.pours.count)
                    let availableWidth = proxy.size.width - (spacing * CGFloat(count - 1))
                    let fittedWidth = availableWidth / CGFloat(count)
                    let itemWidth = max(58, fittedWidth)

                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(Array(recipe.pours.enumerated()), id: \.element.id) { index, pour in
                                pourBar(index: index, pour: pour, width: itemWidth)
                            }
                        }
                        .frame(minWidth: proxy.size.width, alignment: .center)
                        .padding(.top, 4)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(height: 252)
            }
        }
    }

    @ViewBuilder
    private var aiInsight: some View {
        if recipe.generatedByAI, let description = recipe.aiDescription, !description.isEmpty {
            StudioCard(accent: StudioTheme.mint) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Label("AI barista insight", systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        Text("GEMINI")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.1)
                            .foregroundStyle(StudioTheme.mint)
                    }
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func compactMetric(
        _ title: String,
        _ value: String,
        caption: String? = nil,
        captionIcon: String? = nil,
        captionTint: Color = StudioTheme.muted
    ) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.accent)
            if let caption {
                Group {
                    if let captionIcon {
                        Label(caption, systemImage: captionIcon)
                    } else {
                        Text(caption)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(captionTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 45)
    }

    private func pourBar(index: Int, pour: PourStep, width: CGFloat) -> some View {
        let maxVolume = max(1, recipe.pours.map(\.volume).max() ?? 1)
        let fraction = CGFloat(pour.volume) / CGFloat(maxVolume)
        let height = 82 + (78 * fraction)

        return VStack(spacing: 8) {
            Text("\(pour.volume) ml")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            ZStack {
                RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [pourTint(index).opacity(0.42), pourTint(index).opacity(0.18)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(pourTint(index))
                            .frame(height: 3)
                            .clipShape(Capsule())
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                    }

                VStack(spacing: 7) {
                    PourPatternMark(pattern: pour.pattern, color: pourTint(index), size: 30)
                    Text(patternTitle(pour.pattern))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                if pour.agitationBefore {
                    agitationMarker("B")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                if pour.agitationAfter {
                    agitationMarker("A")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .frame(width: max(48, width - 8), height: height)

            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                Text("\(pour.temperature)°C")
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))

            Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                .font(.caption.weight(.bold))
                .lineLimit(1)

            // Hidden rather than removed: dropping the row shortened the
            // column and knocked its temperature and name out of line with
            // the pours beside it.
            Label("\(pour.pauseAfter)s rest", systemImage: "pause.fill")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(StudioTheme.muted)
                .lineLimit(1)
                .opacity(pour.pauseAfter > 0 ? 1 : 0)
                .accessibilityHidden(pour.pauseAfter == 0)
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(index == 0 ? "Bloom" : "Pour \(index + 1)"), \(pour.volume) milliliters, "
                + "\(pour.temperature) degrees, \(patternTitle(pour.pattern))"
                + (pour.pauseAfter > 0 ? ", \(pour.pauseAfter) seconds rest" : "")
        )
    }

    private func agitationMarker(_ timing: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "water.waves")
                .font(.system(size: 9, weight: .heavy))
            Text(timing)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.black.opacity(0.74))
        .frame(width: 25, height: 25)
        .background(StudioTheme.mint, in: Circle())
        .overlay { Circle().stroke(.black.opacity(0.18), lineWidth: 1) }
    }

    /// The bloom wets the bed and the pours extract it — that difference is
    /// worth a colour. The old tint cycled the whole palette by index, so pour
    /// three was brown for no reason and mint meant "done" in one screen and
    /// "third pour" in this one.
    private func pourTint(_ index: Int) -> Color {
        index == 0 ? StudioTheme.crema : StudioTheme.accent
    }

    private func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Centered"
        case .circular: "Circular"
        case .spiral: "Spiral"
        }
    }
}
