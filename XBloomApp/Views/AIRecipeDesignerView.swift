import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

struct AIRecipeDesignerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.selectedTab) private var selectedTab
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini
    @Environment(RecipeGenerationCoordinator.self) private var generation
    @Query(sort: \StoredBean.updatedAt, order: .reverse) private var libraryBeans: [StoredBean]

    /// The coffee this recipe is for, when the screen was opened from one.
    /// Opened from the recipe library there is no bean yet, and there may never
    /// be one — a recipe can be designed for something that is not in the
    /// library at all.
    let bean: BeanProfile?

    @State private var letsAIDecide: Bool
    @State private var rememberPreferences: Bool
    @State private var style: BrewStyle
    @State private var cups: Int
    @State private var selectedAims: Set<RecipeFlavorGoal>
    @State private var goal: String
    @State private var errorMessage: String?
    /// A bean chosen here, when the screen did not arrive with one.
    @State private var pickedBeanID: UUID?
    /// What the coffee is, when it is not in the library. The model reasons
    /// from roast, process and origin; with none of that it is guessing.
    @State private var beanDescription = ""
    @State private var letsAIDecidePours = true
    @State private var pourCount = 3
    @State private var useGrinder = true

    init(bean: BeanProfile?) {
        self.bean = bean
        let defaults = UserDefaults.standard
        let remembers = defaults.bool(forKey: "aiRecipeRememberPreferences")
        let savedStyle = BrewStyle(rawValue: defaults.string(forKey: "aiRecipePreferredStyle") ?? "") ?? .iced
        let savedCups = min(2, max(1, defaults.integer(forKey: "aiRecipePreferredCups")))
        let savedAims = Set(
            (defaults.stringArray(forKey: "aiRecipePreferredAims") ?? [])
                .compactMap(RecipeFlavorGoal.init(rawValue:))
        )
        let migratedAims: Set<RecipeFlavorGoal>
        if !savedAims.isEmpty {
            migratedAims = savedAims
        } else {
            switch defaults.string(forKey: "aiRecipePreferredAim") {
            case "Balanced": migratedAims = [.balanced]
            case "Sweet & round": migratedAims = [.sweetness, .roundness]
            case "Bright & floral": migratedAims = [.brightAcidity, .floral]
            case "Juicy": migratedAims = [.juicy]
            case "Chocolate & body": migratedAims = [.chocolate, .fullBody]
            case "Low acidity": migratedAims = [.lowAcidity]
            case "High clarity": migratedAims = [.clarity]
            default: migratedAims = []
            }
        }

        _letsAIDecide = State(
            initialValue: defaults.object(forKey: "aiRecipeLetsAIDecide") as? Bool ?? false
        )
        _rememberPreferences = State(initialValue: remembers)
        // Iced is what this machine gets asked for most, so it is the opening
        // position rather than hot. A remembered preference still wins.
        _style = State(initialValue: remembers ? savedStyle : .iced)
        _cups = State(initialValue: remembers ? savedCups : 1)
        _selectedAims = State(initialValue: remembers ? migratedAims : [])
        // The bean's own "desired cup" is the best starting note there is, and
        // there simply is not one when the screen opens without a bean.
        let desiredCup = bean?.desiredCup ?? ""
        _goal = State(
            initialValue: remembers
                ? defaults.string(forKey: "aiRecipePreferredGoal") ?? desiredCup
                : desiredCup
        )
        _useGrinder = State(initialValue: defaults.object(forKey: "aiRecipeUseGrinder") as? Bool ?? true)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        hero
                        beanChoice

                        StudioCard(accent: StudioTheme.accent) {
                            VStack(alignment: .leading, spacing: 16) {
                                StudioSectionTitle(
                                    title: "Brew setup",
                                    detail: "Your choice",
                                    icon: "cup.and.saucer.fill"
                                )

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Pour-over style · always chosen by you")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(StudioTheme.muted)
                                    Picker("Pour-over style", selection: $style) {
                                        Text("Hot").tag(BrewStyle.hot)
                                        Text("Iced").tag(BrewStyle.iced)
                                    }
                                    .pickerStyle(.segmented)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    Label("Number of cups", systemImage: "cup.and.saucer.fill")
                                        .font(.subheadline.weight(.semibold))
                                    HStack(spacing: 8) {
                                        // One or two. Three cups needs 500+ ml
                                        // through a single dripper, which is
                                        // past what this machine brews well.
                                        ForEach(1...2, id: \.self) { count in
                                            Button {
                                                cups = count
                                            } label: {
                                                Text(count == 1 ? "1 cup" : "\(count) cups")
                                                    .font(.subheadline.weight(.bold))
                                                    .foregroundStyle(cups == count ? .black : .white.opacity(0.72))
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 11)
                                                    .background(
                                                        cups == count ? StudioTheme.accent : StudioTheme.raised,
                                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        StudioCard(accent: StudioTheme.mint) {
                            VStack(alignment: .leading, spacing: 16) {
                                StudioSectionTitle(
                                    title: "Flavor direction",
                                    detail: letsAIDecide ? "AI-guided" : "Your aim",
                                    icon: "target"
                                )

                                VStack(spacing: 10) {
                                    flavorModeButton(
                                        aiChooses: true,
                                        title: "Best for this bean",
                                        detail: "AI studies the origin, process, roast, and acidity to choose the cup direction.",
                                        icon: "wand.and.sparkles"
                                    )
                                    flavorModeButton(
                                        aiChooses: false,
                                        title: "I'll guide the flavor",
                                        detail: "Combine several cup goals and add your own tasting preference.",
                                        icon: "slider.horizontal.3"
                                    )
                                }

                                if !letsAIDecide {
                                    Divider().overlay(.white.opacity(0.08))

                                    VStack(alignment: .leading, spacing: 10) {
                                        Label("What should the cup aim for?", systemImage: "target")
                                            .font(.subheadline.weight(.semibold))
                                        Text("Select every goal that fits. Compatible goals work together.")
                                            .font(.caption)
                                            .foregroundStyle(StudioTheme.muted)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(Array(RecipeFlavorGoal.allCases.prefix(6))) { aim in
                                                    StudioFlavorGoalChip(
                                                        goal: aim,
                                                        selected: selectedAims.contains(aim)
                                                    ) {
                                                        selectedAims = RecipeFlavorGoal.toggling(aim, in: selectedAims)
                                                    }
                                                }
                                            }
                                        }
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(Array(RecipeFlavorGoal.allCases.suffix(from: 6))) { aim in
                                                    StudioFlavorGoalChip(
                                                        goal: aim,
                                                        selected: selectedAims.contains(aim)
                                                    ) {
                                                        selectedAims = RecipeFlavorGoal.toggling(aim, in: selectedAims)
                                                    }
                                                }
                                            }
                                        }
                                        Label(
                                            "Direct opposites replace each other: Bright ↔ Low acidity, Tea-like ↔ Full body.",
                                            systemImage: "arrow.left.arrow.right"
                                        )
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(StudioTheme.muted)
                                    }

                                    StudioTextField(
                                        title: "Anything else?",
                                        text: $goal,
                                        icon: "text.bubble.fill",
                                        axis: .vertical
                                    )
                                    Text("Add a personal note only if the quick aims do not say enough.")
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.muted)

                                    Toggle(isOn: $rememberPreferences) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Remember my flavor preference")
                                                .font(.subheadline.weight(.semibold))
                                            Text("Use this cup direction as the starting point next time.")
                                                .font(.caption)
                                                .foregroundStyle(StudioTheme.muted)
                                        }
                                    }
                                    .tint(StudioTheme.accent)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                } else {
                                    Label(
                                        "Only the flavor aim is delegated. \(styleTitle(style)) and \(cups) cup\(cups == 1 ? "" : "s") stay exactly as selected above.",
                                        systemImage: "checkmark.shield.fill"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudioTheme.mint)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(StudioTheme.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .transition(.opacity)
                                }
                            }
                        }
                        .animation(.easeInOut(duration: 0.22), value: letsAIDecide)

                        pourChoice

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(StudioTheme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(StudioTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("AI recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                StudioSaveBar(
                    title: alreadyDesigning ? "Designing…" : "Create AI recipe",
                    subtitle: gemini.hasAPIKey
                        ? (alreadyDesigning
                            ? "This coffee already has a recipe on the way."
                            : generationSummary)
                        : "Add your Gemini key in Settings first.",
                    enabled: gemini.hasAPIKey && !alreadyDesigning,
                    compact: true
                ) {
                    startGeneration()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: letsAIDecide) { _, _ in persistPreferences() }
        .onChange(of: rememberPreferences) { _, _ in persistPreferences() }
        .onChange(of: style) { _, _ in persistPreferences() }
        .onChange(of: cups) { _, _ in persistPreferences() }
        .onChange(of: useGrinder) { _, _ in persistPreferences() }
        .onChange(of: selectedAims) { _, _ in persistPreferences() }
        .onChange(of: goal) { _, _ in persistPreferences() }
        // Deliberately no cancel-on-disappear: the request belongs to
        // `RecipeGenerationCoordinator`, and closing this sheet is now the
        // normal way to start one. The library shows it working.
        .onChange(of: generation.lastError) { _, message in
            if let message { errorMessage = message }
        }
    }

    /// Whether this coffee already has a recipe on the way, so the button does
    /// not quietly queue a second one for the same bean.
    private var alreadyDesigning: Bool {
        generation.pending(forBean: activeBean?.id) != nil
    }

    /// Starts the request and leaves. The recipe is written by the backend and
    /// collected into the library, so the library is where the work is watched
    /// — there is nothing left for this screen to show.
    private func startGeneration() {
        persistPreferences()
        errorMessage = nil
        generation.clearLastCompleted()
        generation.start(
            bean: activeBean,
            style: style,
            cups: cups,
            goals: letsAIDecide ? [] : selectedAims.map(\.rawValue).sorted(),
            notes: letsAIDecide ? "" : goal.trimmingCharacters(in: .whitespacesAndNewlines),
            pours: letsAIDecidePours ? nil : pourCount,
            beanDescription: beanDescription,
            useGrinder: useGrinder,
            context: modelContext
        )
        selectedTab?.wrappedValue = 1
        dismiss()
    }

    /// The bean the recipe is actually for: the one this screen was opened
    /// with, or the one picked here.
    private var activeBean: BeanProfile? {
        if let bean { return bean }
        return libraryBeans.first { $0.id == pickedBeanID }?.profile
    }

    private var hero: some View {
        HStack(spacing: 15) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.black)
                .frame(width: 62, height: 62)
                .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("DESIGN WITH GEMINI")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(StudioTheme.accent)
                Text(activeBean?.name ?? "A new recipe")
                    .font(.title2.weight(.bold))
                Text(
                    activeBean.map { profile in
                        [profile.roaster, profile.country, profile.process]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                    } ?? "Choose a coffee below, or describe what is in the hopper"
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    /// Only shown when the screen did not arrive attached to a bean.
    @ViewBuilder
    private var beanChoice: some View {
        if bean == nil {
            StudioCard(accent: StudioTheme.mint) {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSectionTitle(
                        title: "Which coffee?",
                        detail: activeBean == nil ? "Optional" : nil,
                        icon: "leaf.fill"
                    )

                    Menu {
                        Button("No bean — I'll describe it") { pickedBeanID = nil }
                        ForEach(libraryBeans) { stored in
                            Button(stored.name) { pickedBeanID = stored.id }
                        }
                    } label: {
                        HStack {
                            Text(activeBean?.name ?? "No bean attached")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(StudioTheme.muted)
                        }
                        .padding(13)
                        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if activeBean == nil {
                        StudioTextField(
                            title: "What is the coffee?",
                            text: $beanDescription,
                            icon: "text.book.closed.fill",
                            axis: .vertical
                        )
                        Text(
                            "Roast, process, origin, tasting notes — whatever you know. "
                                + "The recipe is designed from this, so \"light Ethiopian "
                                + "natural, fruity\" gets a far better answer than nothing."
                        )
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                    } else {
                        Label("The bean's roast, process and notes are sent with the request.", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioTheme.mint)
                    }
                }
            }
        }
    }

    /// The pour count, which the brief is otherwise written to decide.
    private var pourChoice: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "Pours",
                    detail: letsAIDecidePours ? "AI decides" : "\(pourCount) steps",
                    icon: "drop.fill"
                )
                Toggle(isOn: $letsAIDecidePours) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Let the AI choose")
                            .font(.subheadline.weight(.semibold))
                        Text("It picks the pour count from the roast, process and your cup goal.")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                .tint(StudioTheme.accent)

                if !letsAIDecidePours {
                    HStack(spacing: 8) {
                        ForEach(1...8, id: \.self) { count in
                            Button {
                                pourCount = count
                            } label: {
                                Text("\(count)")
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(pourCount == count ? .black : .white.opacity(0.72))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        pourCount == count ? StudioTheme.accent : StudioTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                GrinderPowerControl(isOn: $useGrinder)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: letsAIDecidePours)
    }


    private func styleTitle(_ style: BrewStyle) -> String {
        style == .iced ? "Iced pour-over" : "Hot pour-over"
    }

    private var generationSummary: String {
        let aim = letsAIDecide
            ? "AI chooses flavor"
            : "\(selectedAims.count) goal\(selectedAims.count == 1 ? "" : "s")"
        return "\(cups) cup\(cups == 1 ? "" : "s") · \(styleTitle(style)) · \(aim)"
    }

    private func flavorModeButton(
        aiChooses: Bool,
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        let selected = letsAIDecide == aiChooses
        return Button {
            letsAIDecide = aiChooses
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(selected ? .black : StudioTheme.muted)
                    .frame(width: 40, height: 40)
                    .background(selected ? StudioTheme.mint : StudioTheme.raised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? StudioTheme.mint : .white.opacity(0.22))
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? StudioTheme.mint.opacity(0.09) : StudioTheme.raised.opacity(0.68),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(selected ? StudioTheme.mint.opacity(0.58) : .white.opacity(0.05), lineWidth: selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(letsAIDecide, forKey: "aiRecipeLetsAIDecide")
        defaults.set(rememberPreferences, forKey: "aiRecipeRememberPreferences")
        guard rememberPreferences else { return }
        defaults.set(style.rawValue, forKey: "aiRecipePreferredStyle")
        defaults.set(cups, forKey: "aiRecipePreferredCups")
        defaults.set(useGrinder, forKey: "aiRecipeUseGrinder")
        defaults.set(selectedAims.map(\.rawValue).sorted(), forKey: "aiRecipePreferredAims")
        defaults.set(goal, forKey: "aiRecipePreferredGoal")
    }
}
