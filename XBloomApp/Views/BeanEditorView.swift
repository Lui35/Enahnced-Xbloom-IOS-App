import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XBloomCore

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
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            StudioTheme.accent,
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
