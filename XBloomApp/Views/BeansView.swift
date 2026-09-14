import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

struct BeansView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini
    @Environment(BeanImportCoordinator.self) private var beanImport
    @Query(sort: \StoredBean.updatedAt, order: .reverse) private var beans: [StoredBean]
    @State private var showingManualEditor = false
    @State private var showingPhotoImporter = false
    @State private var aiBean: BeanProfile?
    @State private var deleting: StoredBean?

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        beanShelfHero

                        if let failure = beanImport.lastError {
                            importFailureCard(failure)
                        }

                        // A bag still being read, on the shelf where it will
                        // land. The request belongs to the app, so this is here
                        // whether or not the importer sheet is still open.
                        ForEach(beanImport.pending) { item in
                            AIGeneratingCard(
                                title: beanImport.isUploading(item.id) ? "Uploading bag photos"
                                    : item.serverAccepted ? "Discovering your coffee" : "Checking your import",
                                subtitle: beanImport.isUploading(item.id)
                                    ? "Uploading \(item.photoCount) photos.\nKeep the app open."
                                    : item.serverAccepted
                                        ? "Reading \(item.photoCount) photo\(item.photoCount == 1 ? "" : "s").\nYou can close the app."
                                        : "Checking the server.\nPlease stay connected.",
                                icon: "doc.viewfinder.fill",
                                tint: StudioTheme.crema,
                                placeholderCount: 2
                            ) {
                                beanImport.cancel(item.id)
                            }
                            .transition(.popIn)
                        }

                        ForEach(beans.filter { !$0.archived }) { bean in
                            beanShelfCard(bean)
                            .transition(.popIn)
                            .contextMenu {
                                Button("Archive", systemImage: "archivebox") {
                                    archive(bean)
                                }
                                Button("Delete bag", systemImage: "trash", role: .destructive) {
                                    deleting = bean
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
                if beans.filter({ !$0.archived }).isEmpty && beanImport.pending.isEmpty && beanImport.lastError == nil {
                    ContentUnavailableView(
                        "No beans",
                        systemImage: "leaf",
                        description: Text("Add a bag manually or scan its label.")
                    )
                }
            }
            .navigationTitle("Beans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
        .confirmationDialog(
            "Delete this bag?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete the bag and its recipes", role: .destructive) {
                if let deleting { try? LocalLibrary.delete(bean: deleting, in: modelContext) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(
                "The bag and its recipes will be removed from your library and account. "
                    + "Past brews, ratings, and maintenance usage will stay. "
                    + "Archive instead if you want to keep the bag and its recipes."
            )
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: beanImport.pending.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: beans.count)
    }

    /// An import that failed after its sheet was closed would otherwise vanish
    /// without a word.
    private func importFailureCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StudioTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("The bag was not read")
                    .font(.subheadline.weight(.bold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
            }
            Spacer(minLength: 0)
            Button {
                beanImport.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(StudioTheme.raised, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                .stroke(StudioTheme.warning.opacity(0.4), lineWidth: 1.5)
        }
    }

    private var beanShelfHero: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("COFFEE COLLECTION")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(StudioTheme.crema)
                Text("Your bean shelf")
                    .font(.title.weight(.bold))
                Text("Your coffee, tasting notes, and bag inventory.")
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
                    .foregroundStyle(StudioTheme.crema)
            }
            .frame(width: 76, height: 82)
            .background(StudioTheme.crema.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(20)
        .background(
            StudioTheme.panel,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(StudioTheme.crema.opacity(0.25), lineWidth: 1)
        }
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
                                    StudioTheme.accent.opacity(0.14)
                                )
                            Image(systemName: "leaf.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(StudioTheme.crema)
                        }
                        .frame(width: 62, height: 62)

                        VStack(alignment: .leading, spacing: 5) {
                            if bean.needsVerification {
                                Label("NEEDS REVIEW", systemImage: "eye.trianglebadge.exclamationmark.fill")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(StudioTheme.warning, in: Capsule())
                            }
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
                                    .foregroundStyle(StudioTheme.crema)
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
                                .foregroundStyle(StudioTheme.crema)
                        }
                        ProgressView(value: remaining, total: initialWeight)
                            .tint(StudioTheme.crema)
                        }
                    .padding(.top, 4)
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
                            Text("Design with AI")
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
            StudioTheme.panel,
            in: RoundedRectangle(cornerRadius: 27, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
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
