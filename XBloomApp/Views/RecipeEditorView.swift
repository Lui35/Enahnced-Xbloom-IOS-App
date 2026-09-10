import SwiftData
import SwiftUI
import XBloomCore

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var recipe: Recipe
    @State private var expandedPourID: UUID?
    let onSave: (Recipe) -> Void

    private let parameterColumns = [
        GridItem(.flexible()),
    ]

    private var issues: [ValidationIssue] {
        RecipeValidator.validate(recipe)
    }

    private var canSave: Bool {
        !issues.contains { $0.severity == .error }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    // These cards are highly interactive and their values update
                    // frequently. Keeping them resident avoids LazyVStack
                    // re-anchoring the scroll position when a pattern or agitation
                    // value changes.
                    VStack(spacing: 20) {
                        recipeIdentity
                        coffeeSettings
                        poursEditor
                        validationCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Coffee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .safeAreaInset(edge: .bottom) {
                StudioSaveBar(
                    title: "Save",
                    subtitle: saveMessage,
                    enabled: canSave
                ) {
                    onSave(recipe)
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if recipe.brewStyle == .cold {
                recipe.brewStyle = .iced
            }
        }
        .onChange(of: recipe.brewStyle) { _, style in
            if style == .hot {
                recipe.iceGrams = 0
            }
        }
    }

    private var recipeIdentity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("RECIPE")
                            .font(.caption2.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(.black.opacity(0.55))
                        if recipe.name.isEmpty {
                            Text("REQUIRED")
                                .font(.caption2.weight(.heavy))
                                .tracking(0.8)
                                .foregroundStyle(StudioTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.72), in: Capsule())
                                .transition(.opacity)
                        }
                    }
                    // Styled as a field, not as a heading. Set in the card's
                    // own text colour on the card's own background it read as a
                    // title someone had left blank, and the only hint that it
                    // was required was a validation error further down.
                    TextField(
                        "",
                        text: $recipe.name,
                        prompt: Text("Name your recipe").foregroundStyle(.black.opacity(0.5))
                    )
                        .font(.title2.weight(.bold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            .white.opacity(recipe.name.isEmpty ? 0.34 : 0.2),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    recipe.name.isEmpty ? .black.opacity(0.5) : .black.opacity(0.14),
                                    lineWidth: recipe.name.isEmpty ? 1.5 : 1
                                )
                        }
                        .animation(.snappy(duration: 0.2), value: recipe.name.isEmpty)
                }
                Spacer()
                Text("\(recipe.pours.count)")
                    .font(.system(size: 68, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black.opacity(0.26))
                    .overlay(alignment: .topTrailing) {
                        Text("POURS")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black.opacity(0.36))
                    }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("1:\(String(format: "%.1f", recipe.ratio))")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .frame(width: 1, height: 34)
                Text("\(recipe.totalWater) ml")
                    .font(.title.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(.black.opacity(0.76))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [StudioTheme.accent, StudioTheme.accentDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        }
        .padding(.top, 8)
    }

    private var coffeeSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Coffee")
                    .font(.largeTitle.weight(.semibold))
            }

            StudioCard {
                VStack(spacing: 14) {
                    GrinderPowerControl(isOn: $recipe.useGrinder)

                    Picker("Brew style", selection: $recipe.brewStyle) {
                        Text("Hot pour-over").tag(BrewStyle.hot)
                        Text("Iced pour-over").tag(BrewStyle.iced)
                    }
                    .pickerStyle(.segmented)

                    LazyVGrid(columns: parameterColumns, spacing: 12) {
                        StudioDialBox(
                            title: "Dose",
                            value: Binding(
                                get: { recipe.dose },
                                set: { recipe.dose = $0 }
                            ),
                            range: 5...30,
                            step: 0.5,
                            unit: "g",
                            decimals: 1
                        )

                        StudioDialBox(
                            title: "Coffee : water",
                            value: Binding(
                                get: { recipe.ratio },
                                set: { setTargetRatio($0) }
                            ),
                            range: recipe.brewStyle == .iced ? 7.5...20 : 12...20,
                            step: 0.1,
                            prefix: "1:",
                            decimals: 1,
                            tint: StudioTheme.mint
                        )

                        if recipe.brewStyle == .iced {
                            StudioDialBox(
                                title: "Ice",
                                value: Binding(
                                    get: { Double(recipe.iceGrams) },
                                    set: { recipe.iceGrams = Int($0.rounded()) }
                                ),
                                range: 0...500,
                                step: 5,
                                unit: "g",
                                tint: StudioTheme.iced
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        StudioDialBox(
                            title: "Grind size",
                            value: Binding(
                                get: { Double(recipe.grindSize) },
                                set: { recipe.grindSize = Int($0.rounded()) }
                            ),
                            range: 1...80,
                            unit: "",
                            tint: StudioTheme.crema,
                            caption: GrindSizeGuide.method(for: recipe.grindSize)
                        )
                        .opacity(recipe.useGrinder ? 1 : 0.42)
                        .allowsHitTesting(recipe.useGrinder)

                        StudioDialBox(
                            title: "Grinder speed",
                            value: Binding(
                                get: { Double(recipe.rpm.rawValue) },
                                set: { setRPM($0) }
                            ),
                            range: 60...120,
                            step: 10,
                            unit: "RPM",
                            tint: StudioTheme.accent
                        )
                        .opacity(recipe.useGrinder ? 1 : 0.42)
                        .allowsHitTesting(recipe.useGrinder)
                    }
                }
            }
        }
    }

    private var poursEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text("Pours")
                    .font(.largeTitle.weight(.semibold))
                Text("\(recipe.totalWater)/500 ml")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(recipe.totalWater > 500 ? StudioTheme.warning : StudioTheme.mint)
                Spacer()
                Button {
                    let newPour = PourStep(volume: 50, temperature: 92, flowRate: 3.2)
                    recipe.pours.append(newPour)
                    expandedPourID = newPour.id
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(StudioTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(recipe.pours.count >= 8)
            }

            ForEach(Array(recipe.pours.indices), id: \.self) { index in
                pourCard(index: index)
            }
        }
    }

    private func pourCard(index: Int) -> some View {
        let pour = recipe.pours[index]
        let expanded = expandedPourID == pour.id
        let percentage = recipe.totalWater > 0
            ? Int((Double(pour.volume) / Double(recipe.totalWater) * 100).rounded())
            : 0

        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    expandedPourID = expanded ? nil : pour.id
                }
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text("\(percentage)")
                                .font(.system(size: 48, weight: .light, design: .rounded))
                                .monospacedDigit()
                            Text("%")
                                .font(.title2.weight(.bold))
                        }
                    }
                    .frame(width: 105, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(pour.volume) ml", systemImage: "drop.fill")
                        HStack(spacing: 8) {
                            PourPatternMark(pattern: pour.pattern, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(patternTitle(pour.pattern))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text("\(pour.temperature)°C")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                        // Every pattern uses the same two-line footprint. This
                        // prevents "Spiral" fitting on one line while longer
                        // names wrap and change the card's height.
                        .frame(height: 42, alignment: .leading)
                        HStack(spacing: 12) {
                            Text("\(String(format: "%.1f", pour.flowRate)) ml/s")
                            Text("·")
                            Text("\(pour.pauseAfter)s rest")
                        }
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                        HStack(spacing: 6) {
                            Text("Agitation")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    (pour.agitationBefore || pour.agitationAfter)
                                        ? StudioTheme.mint
                                        : StudioTheme.muted
                                )
                            AgitationTimingMarks(
                                before: pour.agitationBefore,
                                after: pour.agitationAfter,
                                size: 20,
                                showInactive: true
                            )
                        }
                        .frame(height: 28)
                    }
                    .font(.headline.monospacedDigit())

                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.headline.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(StudioTheme.accent)
                }
                .contentShape(Rectangle())
                .padding(18)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(.white.opacity(0.10))
                pourDetails(index: index)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                .stroke(expanded ? StudioTheme.accent : .white.opacity(0.08), lineWidth: expanded ? 2 : 1)
        }
    }

    private func pourDetails(index: Int) -> some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: parameterColumns, spacing: 12) {
                StudioDialBox(
                    title: "Volume",
                    value: Binding(
                        get: { Double(recipe.pours[index].volume) },
                        set: { recipe.pours[index].volume = Int($0.rounded()) }
                    ),
                    range: 0...240,
                    unit: "ml",
                    height: 84
                )
                StudioDialBox(
                    title: "Temperature",
                    value: Binding(
                        get: { Double(recipe.pours[index].temperature) },
                        set: { recipe.pours[index].temperature = Int($0.rounded()) }
                    ),
                    range: 80...96,
                    unit: "°C",
                    tint: StudioTheme.crema,
                    height: 84
                )
                StudioDialBox(
                    title: "Flow rate",
                    value: Binding(
                        get: { recipe.pours[index].flowRate },
                        set: { recipe.pours[index].flowRate = $0 }
                    ),
                    range: 3...3.5,
                    step: 0.1,
                    unit: "ml/s",
                    decimals: 1,
                    tint: .blue,
                    height: 84
                )
                StudioDialBox(
                    title: "Pause after",
                    value: Binding(
                        get: { Double(recipe.pours[index].pauseAfter) },
                        set: { recipe.pours[index].pauseAfter = Int($0.rounded()) }
                    ),
                    range: 0...120,
                    unit: "s",
                    tint: .purple,
                    height: 84
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Pour pattern")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                PourPatternSelector(
                    selection: Binding(
                        get: { recipe.pours[index].pattern },
                        set: { recipe.pours[index].pattern = $0 }
                    )
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Agitation timing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                VStack(spacing: 10) {
                    agitationButton(
                        phase: .before,
                        isOn: recipe.pours[index].agitationBefore
                    ) {
                        setAgitation(
                            !recipe.pours[index].agitationBefore,
                            phase: .before,
                            at: index
                        )
                    }
                    agitationButton(
                        phase: .after,
                        isOn: recipe.pours[index].agitationAfter
                    ) {
                        setAgitation(
                            !recipe.pours[index].agitationAfter,
                            phase: .after,
                            at: index
                        )
                    }
                }
            }

            if recipe.pours.count > 1 {
                Button(role: .destructive) {
                    let removedID = recipe.pours[index].id
                    recipe.pours.remove(at: index)
                    if expandedPourID == removedID { expandedPourID = nil }
                } label: {
                    Label("Remove this pour", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func agitationButton(
        phase: AgitationPhase,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AgitationPhaseMark(phase: phase, active: isOn, size: 27)
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase == .before ? "Before pour" : "After pour")
                        .font(.subheadline.weight(.bold))
                    Text(phase == .before ? "Agitate, then begin pouring" : "Agitate after this pour finishes")
                        .font(.caption)
                        .foregroundStyle(isOn ? .black.opacity(0.62) : StudioTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Text(isOn ? "ON" : "OFF")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        isOn ? Color.black.opacity(0.10) : Color.white.opacity(0.06),
                        in: Capsule()
                    )
            }
            .foregroundStyle(isOn ? .black : .white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                isOn ? StudioTheme.accent : StudioTheme.raised,
                in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func setAgitation(_ enabled: Bool, phase: AgitationPhase, at index: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch phase {
            case .before:
                recipe.pours[index].agitationBefore = enabled
            case .after:
                recipe.pours[index].agitationAfter = enabled
            }
        }
    }

    @ViewBuilder
    private var validationCard: some View {
        if !issues.isEmpty {
            StudioCard(accent: issues.contains(where: { $0.severity == .error }) ? StudioTheme.danger : StudioTheme.warning) {
                VStack(alignment: .leading, spacing: 10) {
                    StudioSectionTitle(title: "Recipe checks", icon: "checkmark.shield")
                    ForEach(issues) { issue in
                        Label(
                            issue.message,
                            systemImage: issue.severity == .error
                                ? "xmark.octagon.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(issue.severity == .error ? StudioTheme.danger : StudioTheme.warning)
                    }
                }
            }
        }
    }

    private var saveMessage: String {
        if let error = issues.first(where: { $0.severity == .error }) {
            return error.message
        }
        if let warning = issues.first {
            return warning.message
        }
        return "\(recipe.totalWater) ml · 1:\(String(format: "%.1f", recipe.ratio)) · \(recipe.pours.count) pours"
    }

    private func setRPM(_ rawValue: Double) {
        let choices = GrinderRPM.allCases.filter { $0 != .off }
        recipe.rpm = choices.min {
            abs(Double($0.rawValue) - rawValue) < abs(Double($1.rawValue) - rawValue)
        } ?? .rpm80
    }

    private func setTargetRatio(_ ratio: Double) {
        guard !recipe.pours.isEmpty else { return }
        let desiredWater = max(1, min(500, Int((recipe.dose * ratio).rounded())))
        let currentWater = max(1, recipe.totalWater)
        var volumes = recipe.pours.map {
            min(240, max(0, Int((Double($0.volume) / Double(currentWater) * Double(desiredWater)).rounded())))
        }
        var difference = desiredWater - volumes.reduce(0, +)
        var index = volumes.count - 1
        var attempts = 0
        while difference != 0 && attempts < 2_000 {
            if difference > 0, volumes[index] < 240 {
                volumes[index] += 1
                difference -= 1
            } else if difference < 0, volumes[index] > 0 {
                volumes[index] -= 1
                difference += 1
            }
            index = index == 0 ? volumes.count - 1 : index - 1
            attempts += 1
        }
        for index in recipe.pours.indices {
            recipe.pours[index].volume = volumes[index]
        }
    }

    private func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Centered"
        case .circular: "Circular"
        case .spiral: "Spiral"
        }
    }

    private func patternIcon(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "circle.circle.fill"
        case .circular: "circle.dotted"
        case .spiral: "tropicalstorm"
        }
    }
}
