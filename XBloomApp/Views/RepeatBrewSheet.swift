import SwiftData
import SwiftUI
import XBloomCore

struct RepeatBrewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var session
    @Query private var beans: [StoredBean]
    let entry: BrewHistoryEntry
    @State private var confirmedRecipe: Recipe?
    @State private var errorMessage: String?

    private var recipe: Recipe? { try? RepeatBrew.recipe(from: entry) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(entry.recipeName).font(.title2.bold())
                    Text("Repeat the saved recipe from \(entry.completedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .foregroundStyle(StudioTheme.muted)
                    if let recipe {
                        StudioCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Exact saved recipe", systemImage: "clock.arrow.circlepath")
                                    .font(.headline).foregroundStyle(StudioTheme.mint)
                                Text(String(format: "%.1f g dose · %d ml water · grind %d", recipe.dose, recipe.totalWater, recipe.grindSize))
                                    .font(.subheadline.monospacedDigit())
                                Text(recipe.useGrinder ? "Grinder on · \(recipe.rpm.rawValue) RPM" : "Use pre-ground coffee")
                                    .font(.subheadline)
                                ForEach(Array(recipe.pours.enumerated()), id: \.offset) { index, pour in
                                    Text("Pour \(index + 1): \(pour.volume) ml · \(pour.temperature)°C")
                                        .font(.caption).foregroundStyle(StudioTheme.muted)
                                }
                            }
                        }
                        if let beanID = recipe.beanID, !beans.contains(where: { $0.id == beanID }) {
                            Label("The original bag is no longer in your library. Its inventory will not be changed.", systemImage: "leaf")
                                .font(.subheadline).foregroundStyle(StudioTheme.warning)
                        }
                        Text(recipe.useGrinder
                             ? "Measure the saved dose, load the grinder, and place the dripper and server before starting."
                             : "Prepare the saved dose of ground coffee, and place the dripper and server before starting.")
                            .font(.subheadline).foregroundStyle(StudioTheme.muted)
                        Button {
                            if !machine.isConnected { machine.connect(); return }
                            do {
                                let exact = try RepeatBrew.recipe(from: entry)
                                guard session.presentation == nil else { return }
                                confirmedRecipe = exact
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        } label: {
                            Label(machine.isConnected ? "Start this exact brew" : "Connect to brew",
                                  systemImage: machine.isConnected ? "play.fill" : "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(machine.isSendingRecipe || session.presentation != nil)
                        if let error = machine.lastError {
                            Text(error).font(.caption).foregroundStyle(StudioTheme.warning)
                        }
                    } else {
                        ContentUnavailableView("Exact recipe unavailable", systemImage: "clock.badge.questionmark",
                            description: Text("This brew has no usable saved recipe. Choose one from Recipes instead."))
                    }
                }.padding(20)
            }
            .background(StudioTheme.background)
            .navigationTitle("Brew again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            guard let confirmedRecipe, session.presentation == nil else { return }
            self.confirmedRecipe = nil
            session.present(recipe: confirmedRecipe, mode: .live)
        }
        .alert("Could not start brew", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }
}
