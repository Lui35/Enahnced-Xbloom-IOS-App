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
    @Query(sort: \StoredBrew.completedAt, order: .reverse) private var brews: [StoredBrew]

    @AppStorage("maintenance.grinderBrush") private var brushDoneAt: Double = 0
    @AppStorage("maintenance.grinderTablets") private var tabletsDoneAt: Double = 0
    @AppStorage("maintenance.descale") private var descaleDoneAt: Double = 0

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    overview
                    ForEach(MaintenanceTask.allCases) { task in
                        card(for: task)
                    }
                    sourceNote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - What the machine has done

    /// Real brews only. A preview never touched the machine, so it cannot wear
    /// anything out — the same reason it should never have debited a bean bag.
    private var realBrews: [StoredBrew] {
        brews.filter { $0.wasSimulated != true }
    }

    private var firstBrewAt: Date? { realBrews.last?.completedAt }

    private func doneAt(_ task: MaintenanceTask) -> Date? {
        let stamp: Double
        switch task {
        case .grinderBrush: stamp = brushDoneAt
        case .grinderTablets: stamp = tabletsDoneAt
        case .descale: stamp = descaleDoneAt
        }
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    private func markDone(_ task: MaintenanceTask, at date: Date?) {
        let stamp = date?.timeIntervalSince1970 ?? 0
        switch task {
        case .grinderBrush: brushDoneAt = stamp
        case .grinderTablets: tabletsDoneAt = stamp
        case .descale: descaleDoneAt = stamp
        }
        if date != nil { MachineFeedback.acknowledged() }
    }

    private func usage(for task: MaintenanceTask) -> MaintenanceUsage {
        let recorded = doneAt(task)
        let since = recorded ?? firstBrewAt ?? Date()
        let counted = realBrews.filter { $0.completedAt > since }
        // The dose lives in the recipe snapshot, and only a recipe that grinds
        // put beans through the burrs — a pre-ground brew wears nothing.
        let ground = counted.compactMap { brew -> (Date, Double)? in
            guard let recipe = brew.entry?.recipeSnapshot, recipe.useGrinder else { return nil }
            return (brew.completedAt, max(0, recipe.dose))
        }
        return MaintenanceUsage(
            since: since,
            wasServiced: recorded != nil,
            groundGrams: ground.reduce(0) { $0 + $1.1 },
            brews: counted.count,
            lastGrinderUseAt: ground.map(\.0).max()
        )
    }

    private func status(for task: MaintenanceTask) -> MaintenanceStatus {
        Maintenance.status(task, usage: usage(for: task))
    }

    // MARK: - Layout

    private var overview: some View {
        let due = MaintenanceTask.allCases.filter { status(for: $0).isDue }
        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: due.isEmpty ? 1 : Double(3 - due.count) / 3)
                    .stroke(
                        due.isEmpty ? StudioTheme.mint : StudioTheme.warning,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.3), value: due.count)
                VStack(spacing: 1) {
                    Text("\(3 - due.count)")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of 3 up to date")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                }
            }
            .frame(width: 156, height: 156)

            Text(due.isEmpty ? "Nothing needs doing" : due.map(\.title).joined(separator: " · "))
                .font(.title3.weight(.bold))
                .foregroundStyle(due.isEmpty ? StudioTheme.mint : StudioTheme.warning)
                .multilineTextAlignment(.center)
            Text("Counted from your brew history — grams ground, brews pulled, days since.")
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
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
                    Text(state.isDue ? "Due" : state.isDormant ? "Idle" : "OK")
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
                        markDone(task, at: Date())
                    } label: {
                        Label("Mark as done", systemImage: "checkmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(tint, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if done != nil {
                        Button {
                            markDone(task, at: nil)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(StudioTheme.muted)
                                .frame(width: 44, height: 44)
                                .background(StudioTheme.raised, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear the recorded date")
                    }
                }
            }
        }
    }

    private func progressBar(_ progress: Double, tint: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(StudioTheme.raised)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, progress))))
                    .animation(.smooth(duration: 0.3), value: progress)
            }
        }
        .frame(height: 8)
    }

    private var sourceNote: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                StudioSectionTitle(title: "Where this comes from", icon: "book.closed.fill")
                Text(
                    "The steps are xBloom's own published procedures. The app only "
                        + "counts and reminds: descaling and calibration are started on "
                        + "the machine itself, not over Bluetooth from here."
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
