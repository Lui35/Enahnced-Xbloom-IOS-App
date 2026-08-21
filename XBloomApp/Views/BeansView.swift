import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

struct BeansView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini
    @Query(sort: \StoredBean.updatedAt, order: .reverse) private var beans: [StoredBean]
    @State private var showingManualEditor = false
    @State private var showingPhotoImporter = false
    @State private var aiBean: BeanProfile?

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        beanShelfHero

                        ForEach(beans.filter { !$0.archived }) { bean in
                            beanShelfCard(bean)
                            .contextMenu {
                                Button("Archive", systemImage: "archivebox") {
                                    archive(bean)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
                if beans.filter({ !$0.archived }).isEmpty {
                    ContentUnavailableView(
                        "No beans",
                        systemImage: "leaf",
                        description: Text("Add a bag manually or import its label with Gemini.")
                    )
                }
            }
            .navigationTitle("Beans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                MachineToolbar()
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Add manually", systemImage: "square.and.pencil") {
                            showingManualEditor = true
                        }
                        Button("Import bag photos", systemImage: "camera") {
                            showingPhotoImporter = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingManualEditor) {
                BeanEditorView()
            }
            .sheet(isPresented: $showingPhotoImporter) {
                BeanPhotoImporterView()
            }
            .sheet(item: $aiBean) { profile in
                AIRecipeDesignerView(bean: profile)
            }
        }
    }

    private var beanShelfHero: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PRIVATE COFFEE LIBRARY")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(StudioTheme.mint)
                Text("Your bean shelf")
                    .font(.title.weight(.bold))
                Text("Origin, cup profile, freshness, and inventory—all stored on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                Text("\(beans.filter { !$0.archived }.count)")
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("BAGS")
                    .font(.caption2.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(StudioTheme.mint)
            }
            .frame(width: 76, height: 82)
            .background(StudioTheme.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [StudioTheme.panel, Color(red: 0.08, green: 0.20, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(StudioTheme.mint.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
    }

    private func beanShelfCard(_ bean: StoredBean) -> some View {
        let profile = bean.profile
        let initialWeight = max(1, profile?.initialWeightGrams ?? 250)
        let remaining = max(0, min(bean.remainingWeightGrams, initialWeight))
        let remainingPercent = Int((remaining / initialWeight * 100).rounded())
        let originLine = [
            profile?.country ?? "",
            profile?.region ?? "",
            profile?.process ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")

        return VStack(spacing: 0) {
            NavigationLink {
                BeanDetailView(bean: bean)
            } label: {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [StudioTheme.mint.opacity(0.28), StudioTheme.accent.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "leaf.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(StudioTheme.mint)
                        }
                        .frame(width: 62, height: 62)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(bean.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(bean.roaster.isEmpty ? "Independent coffee" : bean.roaster)
                                .font(.subheadline)
                                .foregroundStyle(StudioTheme.muted)
                            if !originLine.isEmpty {
                                Text(originLine)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudioTheme.mint)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudioTheme.accent)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.06), in: Circle())
                    }

                    HStack(spacing: 8) {
                        if let acidity = profile?.acidityLevel {
                            beanStat("Acidity \(acidity)/5", "sun.max.fill", StudioTheme.crema)
                        } else {
                            beanStat("Acidity unknown", "questionmark.circle.fill", StudioTheme.muted)
                        }
                        if let roast = profile?.roastLevel, !roast.isEmpty {
                            beanStat(roast, "flame.fill", StudioTheme.crema)
                        }
                        if let notes = profile?.tastingNotes, !notes.isEmpty {
                            beanStat("Tasting notes", "text.quote", StudioTheme.accent)
                        }
                    }

                    VStack(spacing: 9) {
                        HStack {
                            Label("Bag remaining", systemImage: "scalemass.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StudioTheme.muted)
                            Spacer()
                            Text("\(String(format: "%.0f", remaining)) g")
                                .font(.headline.monospacedDigit())
                            Text("· \(remainingPercent)%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(StudioTheme.mint)
                        }
                        ProgressView(value: remaining, total: initialWeight)
                            .tint(StudioTheme.mint)
                            .scaleEffect(x: 1, y: 1.8, anchor: .center)
                    }
                    .padding(13)
                    .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(17)
            }
            .buttonStyle(.plain)

            if let profile {
                Button {
                    aiBean = profile
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Design an AI recipe")
                                .font(.subheadline.weight(.bold))
                            Text("You choose style and cups")
                                .font(.caption2)
                                .foregroundStyle(StudioTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(StudioTheme.accent)
                            .frame(width: 26, height: 26)
                            .background(StudioTheme.accent.opacity(0.12), in: Circle())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        StudioTheme.raised,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(StudioTheme.accent.opacity(0.22), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 17)
                .padding(.bottom, 17)
            }
        }
        .background(
            LinearGradient(
                colors: [StudioTheme.panel, Color(red: 0.075, green: 0.11, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }

    private func beanStat(_ title: String, _ icon: String, _ color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(color.opacity(0.10), in: Capsule())
    }

    private func archive(_ bean: StoredBean) {
        if var profile = bean.profile {
            profile.archived = true
            bean.update(with: profile)
        }
        try? modelContext.save()
    }
}

struct BeanDetailView: View {
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
                BeanEditorView(profile: profile, storedBean: bean)
            }
        }
        .sheet(isPresented: $showingRefill) {
            BeanRefillView(bean: bean)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
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

private enum BeanRefillSize: String, CaseIterable, Identifiable {
    case grams250 = "250 g"
    case grams500 = "500 g"
    case custom = "Custom"

    var id: String { rawValue }
}

private struct BeanRefillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini

    let bean: StoredBean

    @State private var size: BeanRefillSize = .grams250
    @State private var customGrams = 300.0
    @State private var roastDate = Date()
    @State private var selections: [PhotosPickerItem] = []
    @State private var preparedImages: [PreparedBeanImage] = []
    @State private var showingCamera = false
    @State private var isReadingLabel = false
    @State private var scannedLabel: BeanPhotoResult?
    @State private var scanMessage: String?
    @State private var errorMessage: String?
    @State private var selectionTask: Task<Void, Never>?
    @State private var scanTask: Task<Void, Never>?

    private var refillGrams: Double {
        switch size {
        case .grams250: 250
        case .grams500: 500
        case .custom: min(1_000, max(50, customGrams))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        refillHero
                        sizeCard
                        freshnessCard
                        photoCard

                        if let scanMessage {
                            Label(scanMessage, systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(StudioTheme.mint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(StudioTheme.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(StudioTheme.warning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(StudioTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 110)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Refill bag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                StudioSaveBar(
                    title: "Refill \(Int(refillGrams)) g",
                    subtitle: "New bag · \(roastDate.formatted(date: .abbreviated, time: .omitted))"
                ) {
                    refill()
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraCaptureView { image in
                    if let data = BeanImagePreparer.jpegData(from: image) {
                        appendImage(data)
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: selections) {
                selectionTask?.cancel()
                selectionTask = Task { await prepareSelections() }
            }
        }
        .overlay {
            if isReadingLabel {
                AIProcessingOverlay(
                    title: "Reading the new bag",
                    messages: [
                        "Finding the roast and lot details…",
                        "Comparing origin, process, and variety…",
                        "Checking what changed on this label…",
                    ],
                    systemImage: "camera.viewfinder",
                    tint: StudioTheme.mint
                ) {
                    scanTask?.cancel()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            selectionTask?.cancel()
            scanTask?.cancel()
        }
    }

    private var refillHero: some View {
        HStack(spacing: 15) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 70, height: 70)
                .background(StudioTheme.mint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(bean.name)
                    .font(.title3.weight(.bold))
                Text("Start a fresh bag while keeping its recipes and brew history connected.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var sizeCard: some View {
        StudioCard(accent: StudioTheme.mint) {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(title: "New bag size", detail: "Up to 1 kg", icon: "bag.fill")
                HStack(spacing: 9) {
                    ForEach(BeanRefillSize.allCases) { option in
                        Button {
                            size = option
                        } label: {
                            Text(option.rawValue)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(size == option ? .black : .white)
                                .background(
                                    size == option ? StudioTheme.mint : StudioTheme.raised,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sensoryFeedback(.selection, trigger: size)

                if size == .custom {
                    StudioDialBox(
                        title: "Custom refill",
                        value: $customGrams,
                        range: 50...1_000,
                        step: 10,
                        unit: "g",
                        tint: StudioTheme.mint,
                        height: 82
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.smooth(duration: 0.22), value: size)
    }

    private var freshnessCard: some View {
        StudioCard(accent: StudioTheme.crema) {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(title: "Freshness", detail: "New bag", icon: "calendar.badge.clock")
                DatePicker(
                    "Roast date",
                    selection: $roastDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .tint(StudioTheme.crema)
                Text("The bean record’s update date becomes today, and this roast date replaces the previous bag’s date.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    private var photoCard: some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 13) {
                StudioSectionTitle(
                    title: "Check the new label",
                    detail: preparedImages.isEmpty ? "Optional" : "\(preparedImages.count)/2 photos",
                    icon: "camera.viewfinder"
                )
                Text("Add the front or back label if the lot, process, origin, tasting notes, or roast information may have changed.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)

                if !preparedImages.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(preparedImages) { image in
                            Image(uiImage: image.preview)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }

                HStack(spacing: 10) {
                    PhotosPicker(selection: $selections, maxSelectionCount: 2, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(preparedImages.count >= 2)
                    }
                }

                if !preparedImages.isEmpty {
                    Button {
                        scanTask?.cancel()
                        scanTask = Task { await readNewLabel() }
                    } label: {
                        HStack {
                            if isReadingLabel {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isReadingLabel ? "Comparing label…" : "Check changes with Gemini")
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReadingLabel || !gemini.hasAPIKey)
                    .opacity(gemini.hasAPIKey ? 1 : 0.45)

                    if !gemini.hasAPIKey {
                        Text("Add your Gemini key in Settings to compare label details. You can still refill without scanning.")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
            }
        }
    }

    @MainActor
    private func prepareSelections() async {
        preparedImages = []
        scannedLabel = nil
        scanMessage = nil
        for selection in selections.prefix(2) {
            guard !Task.isCancelled else { return }
            guard let raw = try? await selection.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw),
                  let data = BeanImagePreparer.jpegData(from: image) else { continue }
            appendImage(data)
        }
    }

    private func appendImage(_ data: Data) {
        guard preparedImages.count < 2, let image = UIImage(data: data) else { return }
        preparedImages.append(PreparedBeanImage(data: data, preview: image))
        scannedLabel = nil
        scanMessage = nil
    }

    @MainActor
    private func readNewLabel() async {
        isReadingLabel = true
        errorMessage = nil
        defer { isReadingLabel = false }
        do {
            let images = preparedImages.map { ($0.data, "image/jpeg") }
            let result = try await gemini.importBean(images: images)
            try Task.checkCancellation()
            scannedLabel = result
            if let parsedDate = parseRoastDate(result.roastDate) {
                roastDate = min(parsedDate, Date())
            }
            scanMessage = labelChangeSummary(result)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refill() {
        guard var profile = bean.profile else { return }
        if let scannedLabel {
            apply(scannedLabel, to: &profile)
        }
        profile.initialWeightGrams = refillGrams
        profile.remainingWeightGrams = refillGrams
        profile.roastDate = roastDate
        profile.archived = false
        bean.update(with: profile)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ label: BeanPhotoResult, to profile: inout BeanProfile) {
        if !label.name.isEmpty { profile.name = label.name }
        if let value = label.roaster, !value.isEmpty { profile.roaster = value }
        if let value = label.country, !value.isEmpty { profile.country = value }
        if let value = label.region, !value.isEmpty { profile.region = value }
        if let value = label.producer, !value.isEmpty { profile.producer = value }
        if let value = label.species, !value.isEmpty { profile.species = value }
        if let value = label.variety, !value.isEmpty { profile.variety = value }
        if let value = label.process, !value.isEmpty { profile.process = value }
        if let value = label.processDetail, !value.isEmpty { profile.processDetail = value }
        if let value = label.altitudeMASL { profile.altitudeMASL = value }
        if let value = label.roastLevel, !value.isEmpty { profile.roastLevel = value }
        if let value = label.acidityLevel { profile.acidityLevel = value }
        if let value = label.tastingNotes, !value.isEmpty { profile.tastingNotes = value }
    }

    private func labelChangeSummary(_ label: BeanPhotoResult) -> String {
        guard let current = bean.profile else { return "New label read and ready to apply." }
        var changes: [String] = []
        if !label.name.isEmpty, label.name != current.name { changes.append("coffee name") }
        if let value = label.roaster, !value.isEmpty, value != current.roaster { changes.append("roaster") }
        if let value = label.country, !value.isEmpty, value != current.country { changes.append("country") }
        if let value = label.region, !value.isEmpty, value != current.region { changes.append("region") }
        if let value = label.producer, !value.isEmpty, value != current.producer { changes.append("producer") }
        if let value = label.variety, !value.isEmpty, value != current.variety { changes.append("variety") }
        if let value = label.process, !value.isEmpty, value != current.process { changes.append("process") }
        if let value = label.processDetail, !value.isEmpty, value != current.processDetail { changes.append("process details") }
        if let value = label.roastLevel, !value.isEmpty, value != current.roastLevel { changes.append("roast level") }
        if let value = label.tastingNotes, !value.isEmpty, value != current.tastingNotes { changes.append("tasting notes") }
        if label.roastDate != nil { changes.append("roast date") }
        guard !changes.isEmpty else {
            return "Label checked. No visible bean details changed."
        }
        return "Detected changes: \(changes.joined(separator: ", ")). They will be applied when you refill."
    }

    private func parseRoastDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "d MMM yyyy", "MMM d, yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct AIRecipeDesignerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini

    let bean: BeanProfile

    @State private var letsAIDecide: Bool
    @State private var rememberPreferences: Bool
    @State private var style: BrewStyle
    @State private var cups: Int
    @State private var selectedAims: Set<RecipeFlavorGoal>
    @State private var goal: String
    @State private var isGenerating = false
    @State private var createdRecipe: Recipe?
    @State private var rationale: String?
    @State private var errorMessage: String?
    @State private var generationTask: Task<Void, Never>?

    init(bean: BeanProfile) {
        self.bean = bean
        let defaults = UserDefaults.standard
        let remembers = defaults.bool(forKey: "aiRecipeRememberPreferences")
        let savedStyle = BrewStyle(rawValue: defaults.string(forKey: "aiRecipePreferredStyle") ?? "") ?? .hot
        let savedCups = min(3, max(1, defaults.integer(forKey: "aiRecipePreferredCups")))
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
        _style = State(initialValue: remembers ? savedStyle : .hot)
        _cups = State(initialValue: remembers ? savedCups : 1)
        _selectedAims = State(initialValue: remembers ? migratedAims : [])
        _goal = State(
            initialValue: remembers
                ? defaults.string(forKey: "aiRecipePreferredGoal") ?? bean.desiredCup
                : bean.desiredCup
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        hero

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
                                        ForEach(1...3, id: \.self) { count in
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

                        if let createdRecipe {
                            StudioCard(accent: StudioTheme.mint) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Label("AI recipe created", systemImage: "sparkles")
                                            .font(.headline)
                                            .foregroundStyle(StudioTheme.mint)
                                        Spacer()
                                        Text(styleTitle(createdRecipe.brewStyle))
                                            .font(.caption.bold())
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(StudioTheme.accent.opacity(0.18), in: Capsule())
                                    }
                                    Text(createdRecipe.name)
                                        .font(.title3.weight(.bold))
                                    Text("\(createdRecipe.servings ?? cups) cup\(createdRecipe.servings == 1 ? "" : "s") · \(String(format: "%.1f", createdRecipe.dose)) g · \(createdRecipe.totalWater) ml")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(StudioTheme.muted)
                                    if let rationale {
                                        Text(rationale)
                                            .font(.footnote)
                                            .foregroundStyle(.white.opacity(0.74))
                                    }
                                    Label("Saved to Recipes with the AI signature", systemImage: "checkmark.circle.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(StudioTheme.mint)
                                }
                            }
                        }

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
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdRecipe == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if createdRecipe == nil {
                    StudioSaveBar(
                        title: isGenerating ? "Designing…" : "Create AI recipe",
                        subtitle: gemini.hasAPIKey
                            ? generationSummary
                            : "Add your Gemini key in Settings first.",
                        enabled: gemini.hasAPIKey && !isGenerating,
                        compact: true
                    ) {
                        generationTask?.cancel()
                        generationTask = Task { await generate() }
                    }
                }
            }
        }
        .overlay {
            if isGenerating {
                AIProcessingOverlay(
                    title: "Designing your recipe",
                    messages: [
                        "Studying the bean and roast development…",
                        "Balancing dose, grind, and water…",
                        "Composing each pour and rest…",
                        "Validating the program for your xBloom…",
                    ],
                    systemImage: "wand.and.sparkles",
                    tint: StudioTheme.accent
                ) {
                    generationTask?.cancel()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: letsAIDecide) { _, _ in persistPreferences() }
        .onChange(of: rememberPreferences) { _, _ in persistPreferences() }
        .onChange(of: style) { _, _ in persistPreferences() }
        .onChange(of: cups) { _, _ in persistPreferences() }
        .onChange(of: selectedAims) { _, _ in persistPreferences() }
        .onChange(of: goal) { _, _ in persistPreferences() }
        .onDisappear {
            generationTask?.cancel()
            generationTask = nil
        }
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
                Text(bean.name)
                    .font(.title2.weight(.bold))
                Text([bean.roaster, bean.country, bean.process].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    @MainActor
    private func generate() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            persistPreferences()
            let result = try await gemini.generateRecipe(
                for: bean,
                style: style,
                cups: cups,
                goals: letsAIDecide ? [] : selectedAims.map(\.rawValue).sorted(),
                notes: letsAIDecide ? "" : goal.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try Task.checkCancellation()
            let recipe = try result.recipe(
                bean: bean,
                cups: cups,
                requestedStyle: style
            )
            modelContext.insert(StoredRecipe(recipe: recipe))
            try modelContext.save()
            createdRecipe = recipe
            rationale = "\(result.methodName) · \(result.rationale)"
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
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
        defaults.set(selectedAims.map(\.rawValue).sorted(), forKey: "aiRecipePreferredAims")
        defaults.set(goal, forKey: "aiRecipePreferredGoal")
    }
}

struct BeanEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var profile: BeanProfile
    private let storedBean: StoredBean?
    let onSaved: (() -> Void)?

    init(
        profile: BeanProfile = BeanProfile(name: ""),
        storedBean: StoredBean? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        _profile = State(initialValue: profile)
        self.storedBean = storedBean
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        beanIdentity

                        StudioCard(accent: StudioTheme.mint) {
                            VStack(spacing: 14) {
                                StudioSectionTitle(title: "Bag", detail: "Required", icon: "bag.fill")
                                StudioTextField(title: "Coffee name", text: $profile.name, icon: "cup.and.saucer.fill")
                                StudioTextField(title: "Roaster", text: $profile.roaster, icon: "building.2.fill")
                                StudioDialBox(
                                    title: "Bag weight",
                                    value: $profile.initialWeightGrams,
                                    range: 50...1_000,
                                    step: 50,
                                    unit: "g",
                                    tint: StudioTheme.mint
                                )
                            }
                        }

                        StudioCard {
                            VStack(spacing: 14) {
                                StudioSectionTitle(title: "Origin", icon: "globe.americas.fill")
                                fieldPair(
                                    StudioTextField(title: "Country", text: $profile.country, icon: "flag.fill"),
                                    StudioTextField(title: "Region", text: $profile.region, icon: "map.fill")
                                )
                                StudioTextField(title: "Producer", text: $profile.producer, icon: "person.2.fill")
                                fieldPair(
                                    StudioTextField(title: "Variety", text: $profile.variety, icon: "leaf.fill"),
                                    StudioTextField(title: "Altitude (masl)", text: altitudeText, icon: "mountain.2.fill")
                                )
                            }
                        }

                        StudioCard(accent: StudioTheme.crema) {
                            VStack(spacing: 14) {
                                StudioSectionTitle(title: "Coffee profile", icon: "sparkles")
                                StudioMenuField(
                                    title: "Process",
                                    selection: $profile.process,
                                    options: coffeeProcesses,
                                    icon: "arrow.triangle.2.circlepath"
                                )
                                RoastLevelSelector(selection: $profile.roastLevel)
                                AcidityLevelSelector(level: $profile.acidityLevel)
                                StudioTextField(title: "Process details", text: $profile.processDetail, icon: "text.alignleft", axis: .vertical)
                                StudioTextField(title: "Tasting notes", text: $profile.tastingNotes, icon: "nose", axis: .vertical)
                                StudioTextField(title: "Desired cup", text: $profile.desiredCup, icon: "target", axis: .vertical)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle(storedBean == nil ? "New bean" : "Edit bean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                StudioSaveBar(
                    title: storedBean == nil ? "Save bean" : "Update bean",
                    subtitle: profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Enter the coffee name."
                        : storedBean == nil
                            ? "\(String(format: "%.0f", profile.initialWeightGrams)) g · saved locally"
                            : "Updates this local bean record",
                    enabled: !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    save()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var beanIdentity: some View {
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
                Text(profile.name.isEmpty ? "A new bag" : profile.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                Text("Private · stored on this iPhone")
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

    private func fieldPair<Left: View, Right: View>(_ left: Left, _ right: Right) -> some View {
        HStack(alignment: .top, spacing: 12) {
            left.frame(maxWidth: .infinity)
            right.frame(maxWidth: .infinity)
        }
    }

    private var altitudeText: Binding<String> {
        Binding(
            get: { profile.altitudeMASL.map(String.init) ?? "" },
            set: { profile.altitudeMASL = Int($0.filter(\.isNumber)) }
        )
    }

    private var coffeeProcesses: [String] {
        ["Washed", "Natural", "Honey", "Anaerobic", "Wet hulled", "Experimental", "Decaf"]
    }

    private func save() {
        if let storedBean {
            profile.remainingWeightGrams = min(
                profile.initialWeightGrams,
                max(0, profile.remainingWeightGrams)
            )
            storedBean.update(with: profile)
        } else {
            profile.remainingWeightGrams = profile.initialWeightGrams
            modelContext.insert(StoredBean(profile: profile))
        }
        try? modelContext.save()
        onSaved?()
        dismiss()
    }
}

struct BeanPhotoImporterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GeminiService.self) private var gemini
    @State private var selections: [PhotosPickerItem] = []
    @State private var preparedImages: [PreparedBeanImage] = []
    @State private var showingCamera = false
    @State private var isWorking = false
    @State private var draft: BeanProfile?
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var selectionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        importHero
                        photoSlots

                        if !gemini.hasAPIKey {
                            StudioCard(accent: StudioTheme.warning) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("Gemini key needed", systemImage: "key.fill")
                                        .font(.headline)
                                        .foregroundStyle(StudioTheme.warning)
                                    Text("Your key is stored securely in the iPhone Keychain. It is used only when you tap Read bag.")
                                        .font(.subheadline)
                                        .foregroundStyle(StudioTheme.muted)
                                    NavigationLink {
                                        SettingsView()
                                    } label: {
                                        Label("Open AI settings", systemImage: "gearshape.fill")
                                            .font(.subheadline.weight(.bold))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Button {
                            importTask?.cancel()
                            importTask = Task { await importPhotos() }
                        } label: {
                            HStack {
                                if isWorking {
                                    ProgressView().tint(.black)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isWorking ? "Reading the label…" : "Read bag with Gemini")
                            }
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(preparedImages.isEmpty || isWorking || !gemini.hasAPIKey)
                        .opacity(preparedImages.isEmpty || !gemini.hasAPIKey ? 0.45 : 1)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(StudioTheme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(15)
                                .background(StudioTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Import bean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraCaptureView { image in
                    if let data = BeanImagePreparer.jpegData(from: image) {
                        appendImage(data)
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $draft) {
                BeanEditorView(profile: $0) {
                    draft = nil
                    dismiss()
                }
            }
            .onChange(of: selections) {
                selectionTask?.cancel()
                selectionTask = Task { await prepareSelections() }
            }
        }
        .overlay {
            if isWorking {
                AIProcessingOverlay(
                    title: "Discovering this coffee",
                    messages: [
                        "Reading the front and back labels…",
                        "Finding origin, producer, and variety…",
                        "Interpreting process and roast details…",
                        "Preparing a bean profile for review…",
                    ],
                    systemImage: "doc.viewfinder.fill",
                    tint: StudioTheme.mint
                ) {
                    importTask?.cancel()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            importTask?.cancel()
            selectionTask?.cancel()
            importTask = nil
            selectionTask = nil
            preparedImages.removeAll(keepingCapacity: false)
        }
    }

    private var importHero: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 92, height: 92)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text("Photograph the coffee bag")
                .font(.title2.weight(.bold))
            Text("Capture the front and back labels. Gemini extracts the details, then you review everything before it is saved.")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    private var photoSlots: some View {
        StudioCard {
            VStack(spacing: 14) {
                HStack {
                    StudioSectionTitle(title: "Bag photos", detail: "\(preparedImages.count)/2", icon: "photo.stack.fill")
                }
                HStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { index in
                        if preparedImages.indices.contains(index) {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: preparedImages[index].preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 154)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                Button {
                                    preparedImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(.black.opacity(0.72), in: Circle())
                                }
                                .padding(8)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                                .foregroundStyle(.white.opacity(0.18))
                                .frame(maxWidth: .infinity)
                                .frame(height: 154)
                                .overlay {
                                    VStack(spacing: 8) {
                                        Image(systemName: index == 0 ? "rectangle.front.topleft" : "rectangle.backside")
                                        Text(index == 0 ? "Front" : "Back")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(StudioTheme.muted)
                                }
                        }
                    }
                }
                HStack(spacing: 10) {
                    PhotosPicker(selection: $selections, maxSelectionCount: 2, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.accent)
                        .foregroundStyle(.black)
                        .disabled(preparedImages.count >= 2)
                    }
                }
            }
        }
    }

    private func importPhotos() async {
        isWorking = true
        defer { isWorking = false }
        do {
            errorMessage = nil
            let images = preparedImages.map { ($0.data, "image/jpeg") }
            let result = try await gemini.importBean(images: images)
            try Task.checkCancellation()
            draft = BeanProfile(
                name: result.name,
                roaster: result.roaster ?? "",
                country: result.country ?? "",
                region: result.region ?? "",
                producer: result.producer ?? "",
                species: result.species ?? "Arabica",
                variety: result.variety ?? "",
                process: result.process ?? "Washed",
                processDetail: result.processDetail ?? "",
                altitudeMASL: result.altitudeMASL,
                roastLevel: result.roastLevel ?? "Medium-light",
                acidityLevel: result.acidityLevel,
                tastingNotes: result.tastingNotes ?? ""
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func prepareSelections() async {
        preparedImages = []
        for selection in selections.prefix(2) {
            guard !Task.isCancelled else { return }
            guard let raw = try? await selection.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw),
                  let data = BeanImagePreparer.jpegData(from: image) else { continue }
            appendImage(data)
        }
    }

    private func appendImage(_ data: Data) {
        guard preparedImages.count < 2, let image = UIImage(data: data) else { return }
        preparedImages.append(PreparedBeanImage(data: data, preview: image))
    }
}

private struct PreparedBeanImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: UIImage
}
