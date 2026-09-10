import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

private enum BeanRefillSize: String, CaseIterable, Identifiable {
    case grams250 = "250 g"
    case grams500 = "500 g"
    case custom = "Custom"

    var id: String { rawValue }
}

struct BeanRefillView: View {
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
