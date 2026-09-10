import SwiftData
import SwiftUI
import XBloomCore

struct QuickBrewFeedback: View {
    @Environment(\.modelContext) private var modelContext
    let brew: StoredBrew
    @State private var rating = 0
    @State private var tags: Set<String> = []
    @State private var notes = ""
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var showDetails = false
    private let choices = ["Already close", "Too sour", "Too bitter", "Too weak", "Too strong", "Not sweet enough"]

    var body: some View {
        StudioCard(accent: StudioTheme.mint) {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(title: "How was your cup?", detail: "Optional", icon: "star.bubble")
                Text("Taste it when you’re ready. You can also rate it later in History.")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        Button { rating = value; saved = false } label: {
                            Image(systemName: rating >= value ? "star.fill" : "star")
                                .font(.title2).frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(StudioTheme.accent)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Rate \(value) out of 5")
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(choices, id: \.self) { choice in
                        Button {
                            if tags.contains(choice) { tags.remove(choice) } else { tags.insert(choice) }
                            saved = false
                        } label: {
                            Text(choice).font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .foregroundStyle(tags.contains(choice) ? .black : .white)
                                .background(tags.contains(choice) ? StudioTheme.mint : StudioTheme.raised, in: Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(tags.contains(choice) ? .isSelected : [])
                    }
                }
                TextField("Tasting note · optional", text: $notes, axis: .vertical).lineLimit(1...3)
                    .onChange(of: notes) { _, _ in saved = false }
                Button(saved ? "Feedback saved" : "Save feedback") { save() }
                    .buttonStyle(PrimaryActionButtonStyle()).disabled(rating == 0 || saved)
                Button("Detailed feedback & enhancement", systemImage: "slider.horizontal.3") {
                    if rating > 0 || !tags.isEmpty || !notes.isEmpty, !saved, !save() { return }
                    showDetails = true
                }.font(.subheadline)
            }
        }
        .onAppear {
            rating = brew.entry?.rating ?? 0
            tags = Set(brew.entry?.feedbackTags ?? [])
            notes = brew.entry?.notes ?? ""
        }
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                BrewHistoryDetailView(brew: brew)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showDetails = false } } }
            }
        }
        .alert("Could not save feedback", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }

    @discardableResult private func save() -> Bool {
        do {
            try LocalLibrary.saveFeedback(for: brew, rating: rating, tags: tags.sorted(), notes: notes, in: modelContext)
            saved = true
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
