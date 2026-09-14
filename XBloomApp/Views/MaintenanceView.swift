import SwiftData
import SwiftUI
import XBloomCore

/// When the machine last had something done to it, and when it next needs it.
///
/// Everything here is counted out of brew history — grams through the grinder,
/// brews pulled, days since — so nothing has to be logged by hand except the
/// service itself. The machine's own descale and calibration routines are not
/// driven from here; the app says when and how, the machine does it.
struct MaintenanceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredBrew.completedAt, order: .reverse) private var brews: [StoredBrew]
    @Query(sort: \StoredMaintenanceEvent.performedAt, order: .reverse)
    private var services: [StoredMaintenanceEvent]
    @State private var recordingTask: MaintenanceTask?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    overview
                    ForEach(orderedTasks) { task in
                        card(for: task)
                    }
                    recentServices
                    sourceNote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { importLegacyDatesIfNeeded() }
        .sheet(item: $recordingTask) { task in
            MaintenanceServiceSheet(task: task)
        }
        .alert("Could not save maintenance", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - What the machine has done

    /// Real brews only. A preview never touched the machine, so it cannot wear
    /// anything out — the same reason it should never have debited a bean bag.
    private var realBrews: [StoredBrew] {
        brews.filter { $0.wasSimulated != true }
    }

    private func history(_ task: MaintenanceTask) -> [StoredMaintenanceEvent] {
        services.filter { $0.task == task.rawValue }
    }

    private func doneAt(_ task: MaintenanceTask) -> Date? {
        history(task).first?.performedAt
    }

    /// Takes back the most recent record of this service. Only the latest, so
    /// a mis-tap is undone without erasing the history behind it.
    private func undoLast(_ task: MaintenanceTask) {
        guard let latest = history(task).first else { return }
        modelContext.delete(latest)
        do { try modelContext.save() }
        catch {
            modelContext.insert(latest)
            errorMessage = error.localizedDescription
        }
    }

    /// Moves the three dates the first version kept in UserDefaults into the
    /// log, once. Without this, upgrading would silently reset every service to
    /// "never recorded".
    private func importLegacyDatesIfNeeded() {
        let defaults = UserDefaults.standard
        let keys: [(MaintenanceTask, String)] = [
            (.grinderBrush, "maintenance.grinderBrush"),
            (.grinderTablets, "maintenance.grinderTablets"),
            (.descale, "maintenance.descale"),
        ]
        var inserted: [StoredMaintenanceEvent] = []
        var importedKeys: [String] = []
        for (task, key) in keys {
            let stamp = defaults.double(forKey: key)
            guard stamp > 0 else { continue }
            if history(task).isEmpty {
                let event = StoredMaintenanceEvent(
                    task: task, performedAt: Date(timeIntervalSince1970: stamp),
                    note: "Imported from this device"
                )
                modelContext.insert(event)
                inserted.append(event)
            }
            importedKeys.append(key)
        }
        do {
            if !inserted.isEmpty { try modelContext.save() }
            importedKeys.forEach { defaults.removeObject(forKey: $0) }
        } catch {
            inserted.forEach { modelContext.delete($0) }
            errorMessage = error.localizedDescription
        }
    }

    private func usage(for task: MaintenanceTask) -> MaintenanceUsage {
        let recorded = doneAt(task)
        return Maintenance.usage(
            brews: realBrews.compactMap(\.entry),
            servicedAt: recorded
        )
    }

    private func status(for task: MaintenanceTask) -> MaintenanceStatus {
        Maintenance.status(task, usage: usage(for: task))
    }

    // MARK: - Layout

    private var orderedTasks: [MaintenanceTask] {
        MaintenanceTask.allCases.sorted {
            let lhs = status(for: $0), rhs = status(for: $1)
            if lhs.isDue != rhs.isDue { return lhs.isDue }
            if lhs.progress != rhs.progress { return lhs.progress > rhs.progress }
            return $0.rawValue < $1.rawValue
        }
    }

    private var overview: some View {
        let due = orderedTasks.filter { status(for: $0).isDue }
        let lifetime = Maintenance.usage(brews: realBrews.compactMap(\.entry), servicedAt: nil)
        let tint = due.isEmpty ? StudioTheme.mint : StudioTheme.warning
        return StudioCard(accent: tint) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    IconBadge(systemImage: due.isEmpty ? "checkmark.shield.fill" : "wrench.and.screwdriver.fill",
                              tint: tint, size: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(due.isEmpty ? "Ready for your next cup" : "A little care is due")
                            .font(.title2.weight(.bold))
                        Text(due.isEmpty ? "No services are due from your recorded usage."
                             : "\(due.count) service\(due.count == 1 ? " needs" : "s need") attention. Start below.")
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    usageMetric("Recorded brews", value: lifetime.brews.formatted(), icon: "cup.and.saucer.fill")
                    usageMetric("Beans ground", value: lifetime.groundGrams >= 1_000
                                ? String(format: "%.2f kg", lifetime.groundGrams / 1_000)
                                : String(format: "%.0f g", lifetime.groundGrams), icon: "leaf.fill")
                }
                Label("Deleting bags or recipes keeps your brew history and these counts.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func usageMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recentServices: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(title: "Recent care", detail: "\(services.count) recorded", icon: "clock.arrow.circlepath")
                if services.isEmpty {
                    Text("Finished a clean? Record it above, even if you did it on an earlier day.")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                } else {
                    ForEach(Array(services.prefix(5))) { service in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: service.maintenanceTask.map { icon(for: $0) } ?? "wrench.fill")
                                .foregroundStyle(StudioTheme.mint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(service.maintenanceTask?.title ?? service.task)
                                    .font(.subheadline.weight(.semibold))
                                Text(service.performedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(StudioTheme.muted)
                                if let note = service.note, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(StudioTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func card(for task: MaintenanceTask) -> some View {
        let state = status(for: task)
        let done = doneAt(task)
        let tint = tint(for: state)

        return StudioCard(accent: tint) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 14) {
                    IconBadge(systemImage: icon(for: task), tint: tint, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.headline)
                        Text(task.rule)
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Text(state.isDue ? "Due now" : state.isDormant ? "No use yet" : "On track")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(state.isDue ? .black : tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            state.isDue ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.15)),
                            in: Capsule()
                        )
                }

                progressBar(state.progress, tint: tint)

                HStack(alignment: .firstTextBaseline) {
                    Text(state.summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.isDue ? tint : StudioTheme.muted)
                    Spacer(minLength: 8)
                    Text(lastDoneText(done))
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.muted)
                        .multilineTextAlignment(.trailing)
                }

                if let cadence = Maintenance.cadence(
                    of: history(task).map(\.performedAt)
                ).summary {
                    Label(cadence, systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.muted)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(steps(for: task).enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.heavy).monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                                    .frame(width: 22, height: 22)
                                    .background(StudioTheme.raised, in: Circle())
                                Text(step)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                        if let warning = warning(for: task) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(StudioTheme.warning)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("How to do it")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                }
                .tint(tint)

                HStack(spacing: 10) {
                    Button {
                        recordingTask = task
                    } label: {
                        Label("Record service", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(tint, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if done != nil {
                        Button {
                            undoLast(task)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(StudioTheme.muted)
                                .frame(width: 44, height: 44)
                                .background(StudioTheme.raised, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Undo the latest \(task.title.lowercased()) record")
                    }
                }
            }
        }
    }

    private func progressBar(_ progress: Double, tint: Color) -> some View {
        ProgressView(value: min(1, max(0, progress)))
            .tint(tint)
            .accessibilityLabel("Service interval used")
            .accessibilityValue("\(Int(min(1, max(0, progress)) * 100)) percent")
    }

    private var sourceNote: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                StudioSectionTitle(title: "Where this comes from", icon: "book.closed.fill")
                Text(
                    "The steps are xBloom's own published procedures. The app only "
                        + "counts and reminds: descaling and calibration are started on "
                        + "the machine itself, not over Bluetooth from here. Each service "
                        + "you record syncs with your account, so the dates and how often "
                        + "you do them follow you to another device."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    // MARK: - Presentation

    private func tint(for state: MaintenanceStatus) -> Color {
        if state.isDue { return StudioTheme.warning }
        if state.isDormant { return StudioTheme.muted }
        return StudioTheme.mint
    }

    private func icon(for task: MaintenanceTask) -> String {
        switch task {
        case .grinderBrush: "paintbrush.fill"
        case .grinderTablets: "pills.fill"
        case .descale: "drop.triangle.fill"
        }
    }

    private func lastDoneText(_ date: Date?) -> String {
        guard let date else { return "Never recorded" }
        return "Last done \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// xBloom's published procedures. Quantities and settings are theirs; the
    /// grinder-cleaning grind size is 55, which is their figure and not the 50
    /// this app's dial defaults to.
    private func steps(for task: MaintenanceTask) -> [String] {
        switch task {
        case .grinderBrush:
            [
                "Empty the hopper and unplug or switch the machine off.",
                "Sweep the grinder chute with the brush that came with the machine.",
                "Brush out the dock arm area, where grounds collect around the dripper.",
                "Empty and brush the drip tray, then wipe the machine with a damp cotton cloth.",
            ]
        case .grinderTablets:
            [
                "Put the magnetic dosing cup under the grinder outlet.",
                "Open the Grinder screen and set the grind size to 55.",
                "Add one 20 g packet of xBloom grinder cleaning tablets and grind.",
                "Grind 30 g of coffee beans straight after, to push the tablet residue out.",
                "Discard both the tablet grounds and the purge coffee.",
                "Calibrate the grinder while you are here: press the left knob three "
                    + "times on the machine, or use Calibrate Grinder in the official "
                    + "app. It takes about 120 seconds and ends on \"Done\".",
            ]
        case .descale:
            [
                "Put a container holding at least 1 L under the water outlet.",
                "Fill the tank with 250–300 ml of water and mix in about 80–90 ml of "
                    + "descaling solution, following the strength on its own packaging.",
                "Start the descale: Brewer mode on the machine (the middle knob, water "
                    + "drop icon), wait for the temperature to appear, then press the "
                    + "middle knob three times.",
                "Leave it for 30 minutes or more while the solution works.",
                "Discharge whatever solution is left, then rinse the tank thoroughly.",
                "Refill to the maximum line and run the water all the way through to "
                    + "flush the path.",
            ]
        }
    }

    private func warning(for task: MaintenanceTask) -> String? {
        switch task {
        case .grinderTablets:
            "xBloom publish a grind size for this but no speed — leave the speed where "
                + "you normally grind."
        case .descale:
            "No vinegar and no supermarket descaler: xBloom say either can void the "
                + "warranty. Descale more often on hard tap water."
        case .grinderBrush:
            nil
        }
    }
}
