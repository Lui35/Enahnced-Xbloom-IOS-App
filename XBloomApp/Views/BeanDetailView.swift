import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

struct BeanDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let bean: StoredBean
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var storedRecipes: [StoredRecipe]
    @Query(sort: \StoredBrew.completedAt, order: .reverse) private var storedBrews: [StoredBrew]
    @State private var aiBean: BeanProfile?
    @State private var showingEditor = false
    @State private var showingRefill = false

    private var linkedRecipes: [(stored: StoredRecipe, recipe: Recipe)] {
        storedRecipes.compactMap { stored in
            guard let recipe = stored.recipe, recipe.beanID == bean.id else { return nil }
            return (stored, recipe)
        }
    }

    private var beanBrews: [StoredBrew] {
        storedBrews.filter { stored in
            guard let entry = stored.entry else { return false }
            return entry.beanID == bean.id
                || entry.beanSnapshot?.id == bean.id
                || entry.recipeSnapshot?.beanID == bean.id
        }
    }

    private var ratedBrews: [BrewHistoryEntry] {
        beanBrews.compactMap(\.entry).filter { ($0.rating ?? 0) > 0 }
    }

    private var averageRating: Double? {
        guard !ratedBrews.isEmpty else { return nil }
        return Double(ratedBrews.compactMap(\.rating).reduce(0, +)) / Double(ratedBrews.count)
    }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                if let profile = bean.profile {
                    LazyVStack(spacing: 18) {
                        if bean.needsVerification {
                            verifyCard(profile)
                        }
                        detailHero(profile)
                        relationshipOverviewCard(profile)
                        linkedRecipesCard(profile)
                        recentBrewsCard
                        originCard(profile)
                        coffeeProfileCard(profile)
                        cupCard(profile)
                        inventoryCard(profile)
                        recipeIntelligenceCard(profile)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                } else {
                    ContentUnavailableView(
                        "Bean unavailable",
                        systemImage: "leaf",
                        description: Text("This local bean record could not be decoded.")
                    )
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(bean.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if bean.profile != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refill bag", systemImage: "arrow.clockwise.circle.fill") {
                            showingRefill = true
                        }
                        Button("Edit bean", systemImage: "square.and.pencil") {
                            showingEditor = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Bean actions")
                }
            }
        }
        .sheet(item: $aiBean) { profile in
            AIRecipeDesignerView(bean: profile)
        }
        .sheet(isPresented: $showingEditor) {
            if let profile = bean.profile {
                // Going through the details and saving them is the review.
                BeanEditorView(profile: profile, storedBean: bean) { verify() }
            }
        }
        .sheet(isPresented: $showingRefill) {
            BeanRefillView(bean: bean)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
    }

    /// What the AI read off the label, still waiting to be checked.
    ///
    /// It is saved already — losing a read because nobody confirmed it would be
    /// worse than holding a draft — but it says plainly that a machine wrote
    /// it, and asks for the one action that settles it.
    private func verifyCard(_ profile: BeanProfile) -> some View {
        StudioCard(accent: StudioTheme.warning) {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "Check this bag",
                    detail: "Read from your photos",
                    icon: "eye.trianglebadge.exclamationmark.fill"
                )
                Text(
                    "Gemini filled these details in from the label. Correct anything "
                        + "it misread, then confirm — the bag stays flagged until you do."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)

                HStack(spacing: 10) {
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit details", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(StudioTheme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        verify()
                    } label: {
                        Label("Looks right", systemImage: "checkmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(StudioTheme.warning, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func verify() {
        bean.needsVerification = false
        try? modelContext.save()
        MachineFeedback.acknowledged()
    }

    private func relationshipOverviewCard(_ profile: BeanProfile) -> some View {
        let referenceDose = linkedRecipes.first?.recipe.dose ?? 18
        let estimatedDoses = referenceDose > 0
            ? Int(floor(max(0, profile.remainingWeightGrams) / referenceDose))
            : 0

        return StudioCard(accent: StudioTheme.mint) {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(
                    title: "Bean workspace",
                    detail: "Recipes & results",
                    icon: "point.3.connected.trianglepath.dotted"
                )
                HStack(spacing: 9) {
                    relationshipMetric(
                        value: "\(linkedRecipes.count)",
                        label: "Recipes",
                        icon: "list.bullet.rectangle.fill",
                        tint: StudioTheme.accent
                    )
                    relationshipMetric(
                        value: "\(beanBrews.count)",
                        label: "Brews",
                        icon: "cup.and.saucer.fill",
                        tint: StudioTheme.mint
                    )
                    relationshipMetric(
                        value: averageRating.map { String(format: "%.1f", $0) } ?? "—",
                        label: "Rating",
                        icon: "star.fill",
                        tint: StudioTheme.crema
                    )
                }

                HStack(spacing: 12) {
                    Image(systemName: "scalemass.fill")
                        .foregroundStyle(StudioTheme.mint)
                        .frame(width: 36, height: 36)
                        .background(StudioTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("About \(estimatedDoses) dose\(estimatedDoses == 1 ? "" : "s") remaining")
                            .font(.subheadline.weight(.bold))
                        Text("Estimated using \(String(format: "%.1f", referenceDose)) g per brew")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                }
                .padding(12)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
    }

    private func relationshipMetric(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    @ViewBuilder
    private func linkedRecipesCard(_ profile: BeanProfile) -> some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 13) {
                StudioSectionTitle(
                    title: "Recipes for this bean",
                    detail: linkedRecipes.isEmpty ? "None yet" : "\(linkedRecipes.count) linked",
                    icon: "link"
                )

                if linkedRecipes.isEmpty {
                    Text("Create a recipe from this bean and it will stay linked to its brews, ratings, and future AI enhancements.")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                    Button {
                        aiBean = profile
                    } label: {
                        Label("Design the first recipe", systemImage: "wand.and.sparkles")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(StudioTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(linkedRecipes.indices.prefix(4), id: \.self) { index in
                        let item = linkedRecipes[index]
                        NavigationLink {
                            RecipeDetailView(stored: item.stored, recipe: item.recipe)
                        } label: {
                            HStack(spacing: 12) {
                                PourPatternMark(pattern: item.recipe.pours.first?.pattern ?? .spiral, size: 39)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(item.recipe.name)
                                            .font(.subheadline.weight(.bold))
                                            .lineLimit(1)
                                        if item.recipe.generatedByAI {
                                            Image(systemName: "sparkles")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(StudioTheme.accent)
                                        }
                                    }
                                    Text("\(String(format: "%.1f", item.recipe.dose)) g · 1:\(String(format: "%.1f", item.recipe.ratio)) · \(item.recipe.pours.count) pours")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(StudioTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(StudioTheme.accent)
                            }
                            .padding(12)
                            .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentBrewsCard: some View {
        StudioCard(accent: StudioTheme.crema) {
            VStack(alignment: .leading, spacing: 13) {
                StudioSectionTitle(
                    title: "Recent cups",
                    detail: beanBrews.isEmpty ? "No brews" : "\(beanBrews.count) total",
                    icon: "clock.arrow.circlepath"
                )
                if beanBrews.isEmpty {
                    Text("Completed brews using this bean will appear here with their rating and extraction record.")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                } else {
                    ForEach(beanBrews.prefix(3)) { stored in
                        NavigationLink {
                            BrewHistoryDetailView(brew: stored)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: stored.entry?.wasSimulated == true ? "play.rectangle.fill" : "waveform.path.ecg")
                                    .foregroundStyle(StudioTheme.crema)
                                    .frame(width: 37, height: 37)
                                    .background(StudioTheme.crema.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stored.recipeName)
                                        .font(.subheadline.weight(.bold))
                                        .lineLimit(1)
                                    Text(stored.completedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.muted)
                                }
                                Spacer()
                                if let rating = stored.rating {
                                    Label("\(rating)", systemImage: "star.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(StudioTheme.crema)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(StudioTheme.muted)
                            }
                            .padding(12)
                            .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func detailHero(_ profile: BeanProfile) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "leaf.fill")
                .font(.largeTitle)
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 74, height: 74)
                .background(.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("COFFEE LIBRARY")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.black.opacity(0.5))
                Text(profile.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                Text(profile.roaster.isEmpty ? "Roaster not provided" : profile.roaster)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black.opacity(0.78))
        .padding(20)
        .background(
            LinearGradient(colors: [StudioTheme.mint, StudioTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .padding(.top, 8)
    }

    private func originCard(_ profile: BeanProfile) -> some View {
        StudioCard {
            VStack(spacing: 14) {
                StudioSectionTitle(title: "Origin", icon: "globe.americas.fill")
                detailRow("Country", value: profile.country, icon: "flag.fill")
                detailRow("Region", value: profile.region, icon: "map.fill")
                detailRow("Producer", value: profile.producer, icon: "person.2.fill")
                detailRow("Variety", value: profile.variety, icon: "leaf.fill")
                detailRow(
                    "Altitude",
                    value: profile.altitudeMASL.map { "\($0) masl" } ?? "",
                    icon: "mountain.2.fill"
                )
            }
        }
    }

    private func coffeeProfileCard(_ profile: BeanProfile) -> some View {
        StudioCard(accent: StudioTheme.crema) {
            VStack(spacing: 14) {
                StudioSectionTitle(title: "Coffee profile", icon: "sparkles")
                detailRow("Process", value: profile.process, icon: "arrow.triangle.2.circlepath")
                if !profile.processDetail.isEmpty {
                    detailRow("Process details", value: profile.processDetail, icon: "text.alignleft")
                }
                detailRow("Roast level", value: profile.roastLevel, icon: "flame.fill")
                acidityReadout(profile.acidityLevel)
            }
        }
    }

    private func cupCard(_ profile: BeanProfile) -> some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 16) {
                StudioSectionTitle(title: "Cup profile", icon: "nose")
                noteBlock(
                    title: "Tasting notes",
                    value: profile.tastingNotes,
                    placeholder: "No tasting notes provided",
                    icon: "text.quote"
                )
                noteBlock(
                    title: "Desired cup",
                    value: profile.desiredCup,
                    placeholder: "No desired-cup preference saved",
                    icon: "target"
                )
            }
        }
    }

    private func inventoryCard(_ profile: BeanProfile) -> some View {
        let remaining = max(0, min(profile.remainingWeightGrams, profile.initialWeightGrams))
        let fraction = profile.initialWeightGrams > 0 ? remaining / profile.initialWeightGrams : 0
        return StudioCard(accent: StudioTheme.mint) {
            VStack(spacing: 14) {
                StudioSectionTitle(
                    title: "Bag inventory",
                    detail: "\(Int((fraction * 100).rounded()))%",
                    icon: "bag.fill"
                )
                HStack(alignment: .lastTextBaseline) {
                    Text("\(String(format: "%.0f", remaining)) g")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("remaining")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.muted)
                    Spacer()
                    Text("of \(String(format: "%.0f", profile.initialWeightGrams)) g")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(StudioTheme.muted)
                }
                ProgressView(value: remaining, total: max(1, profile.initialWeightGrams))
                    .tint(StudioTheme.mint)
                    .scaleEffect(x: 1, y: 1.8, anchor: .center)

                Button {
                    showingRefill = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text(remaining <= 0 ? "Refill finished bag" : "Refill bag")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudioTheme.muted)
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudioTheme.mint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(StudioTheme.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recipeIntelligenceCard(_ profile: BeanProfile) -> some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 13) {
                StudioSectionTitle(title: "Recipe intelligence", detail: "Gemini", icon: "sparkles")
                Text("Choose Hot or Iced pour-over, cups, and several compatible flavor goals. The bean details are attached automatically.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                Button {
                    aiBean = profile
                } label: {
                    Label("Design an AI recipe", systemImage: "wand.and.sparkles")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 28)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
            Spacer()
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not provided" : value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private func acidityReadout(_ level: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Acidity", systemImage: "sun.max.fill")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                Spacer()
                Text(level.map { "\($0) / 5" } ?? "Unknown / not provided")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(level == nil ? StudioTheme.muted : StudioTheme.crema)
            }
            HStack(spacing: 9) {
                ForEach(1...5, id: \.self) { value in
                    Circle()
                        .fill(value <= (level ?? 0) ? StudioTheme.crema : StudioTheme.raised)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle().stroke(StudioTheme.crema.opacity(0.35), lineWidth: 1)
                        }
                }
            }
        }
        .padding(13)
        .background(StudioTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func noteBlock(title: String, value: String, placeholder: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            Text(value.isEmpty ? placeholder : value)
                .font(.body.weight(.medium))
                .foregroundStyle(value.isEmpty ? StudioTheme.muted : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}
