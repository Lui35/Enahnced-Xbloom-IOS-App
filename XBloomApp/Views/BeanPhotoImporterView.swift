import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

struct BeanPhotoImporterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini
    @Environment(BeanImportCoordinator.self) private var beanImport
    @State private var selections: [PhotosPickerItem] = []
    @State private var preparedImages: [PreparedBeanImage] = []
    @State private var showingCamera = false
    @State private var errorMessage: String?
    /// The import this screen started, so it follows that one and no other.
    @State private var requestID: UUID?
    @State private var selectionTask: Task<Void, Never>?

    /// True while *this* screen's request is still running.
    private var isWorking: Bool {
        guard let requestID else { return false }
        return beanImport.pending.contains { $0.id == requestID }
    }

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
                            startImport()
                        } label: {
                            HStack {
                                if isWorking {
                                    ProgressView().tint(.black)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isWorking ? "Reading the label…" : "Import with AI")
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
                    tint: StudioTheme.mint,
                    leaveTitle: "Back to Beans",
                    onLeave: { dismiss() }
                )
            }
        }
        .preferredColorScheme(.dark)
        // The import belongs to `BeanImportCoordinator` now, so leaving this
        // sheet is a supported way to wait for it. The shelf shows it working.
        .onDisappear {
            selectionTask?.cancel()
            selectionTask = nil
        }
        .onChange(of: beanImport.lastImported) { _, imported in
            // The bag is on the shelf, flagged for review. Nothing more to do
            // here.
            if imported != nil, requestID != nil { dismiss() }
        }
        .onChange(of: beanImport.lastError) { _, message in
            if let message { errorMessage = message }
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
            Text("Capture the front and back labels. The bag goes onto your shelf as soon as Gemini has read it, flagged for you to check.")
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

    private func startImport() {
        errorMessage = nil
        beanImport.clearLastImported()
        requestID = beanImport.start(
            images: preparedImages.map { ($0.data, "image/jpeg") },
            gemini: gemini,
            context: modelContext
        )
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
