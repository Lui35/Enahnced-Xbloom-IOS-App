import SwiftData
import SwiftUI
import XBloomCore

struct SharedRecipePreview: Identifiable {
    let id = UUID()
    let recipe: Recipe
}

struct SharedRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let recipe: Recipe
    let onSaved: () -> Void
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("A recipe to make your own", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(StudioTheme.accent)
                        Text(recipe.name).font(.largeTitle.bold())
                        Text([recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(StudioTheme.muted)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(recipe.dose.formatted()) g coffee · \(recipe.totalWater) ml water")
                                .font(.headline)
                            Text("\(recipe.brewStyle.rawValue.capitalized) · Grind \(recipe.grindSize) · \(recipe.useGrinder ? "\(recipe.programRPM.rawValue) RPM" : "Pre-ground")")
                            if recipe.iceGrams > 0 { Text("Ice: \(recipe.iceGrams) g") }
                        }.studioCard()
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Pours").font(.title2.bold())
                            ForEach(Array(recipe.pours.enumerated()), id: \.offset) { index, pour in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1).  \(pour.volume) ml · \(pour.temperature)°C · \(pour.flowRate.formatted()) ml/s")
                                        .font(.headline)
                                    Text("\(String(describing: pour.pattern).capitalized) · Pause before \(pour.pauseBefore)s / after \(pour.pauseAfter)s")
                                        .font(.caption).foregroundStyle(StudioTheme.muted)
                                    if pour.agitationBefore || pour.agitationAfter {
                                        Text("Agitate \([pour.agitationBefore ? "before" : nil, pour.agitationAfter ? "after" : nil].compactMap { $0 }.joined(separator: "and ")) pouring")
                                            .font(.caption).foregroundStyle(StudioTheme.muted)
                                    }
                                }
                            }
                        }.studioCard()
                        if let description = recipe.aiDescription, !description.isEmpty {
                            Text(description).font(.subheadline).foregroundStyle(StudioTheme.muted).studioCard()
                        }
                        Text("Saving adds a new copy to your Recipes. It won’t replace an existing recipe or start the machine.")
                            .font(.footnote).foregroundStyle(StudioTheme.muted)
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(StudioTheme.warning).font(.subheadline)
                        }
                        Button(saved ? "Saved to Recipes" : "Save to my recipes") { save() }
                            .font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(StudioTheme.accent, in: Capsule())
                            .buttonStyle(.plain)
                            .disabled(saved)
                            .accessibilityIdentifier("recipeLink.save")
                    }.padding(22)
                }
            }
            .navigationTitle("Shared recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .preferredColorScheme(.dark)
        }
    }

    private func save() {
        guard !saved else { return }
        do {
            try LocalLibrary.importSharedRecipe(recipe, in: modelContext)
            saved = true
            MachineFeedback.acknowledged()
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A paste fallback for messaging apps that do not turn custom-scheme URLs into tappable links.
struct RecipeLinkImportView: View {
    @State private var link = ""
    @State private var preview: SharedRecipePreview?
    @State private var errorMessage: String?
    @State private var didSave = false

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Someone sent you a recipe?").font(.title2.bold())
                    Text("Paste their xBloom recipe link to preview it before adding a copy to your library. No sign-in needed.")
                        .font(.subheadline).foregroundStyle(StudioTheme.muted)
                    TextField("xbloom://recipe?data=…", text: $link, axis: .vertical)
                        .lineLimit(3...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding().background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    Button("Preview recipe") {
                        do {
                            guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                throw RecipeShareLink.LinkError.invalidLink
                            }
                            preview = SharedRecipePreview(recipe: try RecipeShareLink.decode(url))
                            errorMessage = nil
                            didSave = false
                        } catch { errorMessage = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).tint(StudioTheme.accent).disabled(link.isEmpty)
                    if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(StudioTheme.warning) }
                    if didSave { Label("Added to Recipes", systemImage: "checkmark.circle.fill").foregroundStyle(StudioTheme.mint) }
                }.padding(22)
            }
        }
        .navigationTitle("Import recipe link")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { item in
            SharedRecipeView(recipe: item.recipe) { didSave = true }
        }
    }
}
