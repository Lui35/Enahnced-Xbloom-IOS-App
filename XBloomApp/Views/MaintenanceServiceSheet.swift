import SwiftData
import SwiftUI
import XBloomCore

/// Records completed care, including work performed before today.
struct MaintenanceServiceSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let task: MaintenanceTask
    @State private var performedAt = Date()
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(task.title, systemImage: "checkmark.seal")
                        .font(.headline)
                    Text("Record this after completing the service. The reminder will count usage from the date you choose.")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                }
                Section("Completed on") {
                    DatePicker("Date and time", selection: $performedAt, in: ...Date())
                }
                Section("Notes · optional") {
                    TextField("Products used or anything to remember", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudioTheme.background)
            .navigationTitle("Record service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                }
            }
        }
        .tint(StudioTheme.mint)
        .preferredColorScheme(.dark)
        .alert("Could not save service", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = StoredMaintenanceEvent(task: task, performedAt: min(performedAt, Date()),
                                           note: trimmed.isEmpty ? nil : trimmed)
        modelContext.insert(event)
        do {
            try modelContext.save()
            MachineFeedback.acknowledged()
            dismiss()
        } catch {
            modelContext.delete(event)
            errorMessage = error.localizedDescription
        }
    }
}
