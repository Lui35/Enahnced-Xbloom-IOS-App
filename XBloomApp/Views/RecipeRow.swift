import SwiftData
import SwiftUI
import XBloomCore

extension Recipe {
    func matchesLibrarySearch(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return [
            name,
            roaster,
            origin,
            aiDescription ?? "",
            brewStyle == .iced ? "iced cold pour-over" : "hot pour-over",
        ]
        .contains { $0.localizedCaseInsensitiveContains(normalized) }
    }
}

struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 14) {
            // The tile carries the three things you sort a library by: whether
            // it is hot or iced, how many pours it takes, and how the water
            // goes on. The stats line no longer repeats the pour count.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                    .fill(styleTint)

                Text(recipe.brewStyle == .iced ? "ICED" : "HOT")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.black.opacity(0.58))
                    .padding(11)

                VStack(alignment: .trailing, spacing: -4) {
                    Text("\(recipe.pours.count)")
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .foregroundStyle(.black.opacity(0.62))
                    Text(recipe.pours.count == 1 ? "POUR" : "POURS")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(.black.opacity(0.42))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 10)
                .padding(.bottom, 9)

                PourPatternMark(
                    pattern: recipe.pours.first?.pattern ?? .center,
                    color: .black.opacity(0.5),
                    size: 22
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(11)
            }
            .frame(width: 92, height: 104)
            .accessibilityElement()
            .accessibilityLabel(
                "\(recipe.brewStyle == .iced ? "Iced" : "Hot"), \(recipe.pours.count) "
                    + "pour\(recipe.pours.count == 1 ? "" : "s"), "
                    + "\(patternName(recipe.pours.first?.pattern ?? .center))"
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(recipe.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if recipe.isFavorite == true {
                        Image(systemName: "heart.fill").foregroundStyle(StudioTheme.danger)
                            .accessibilityLabel("Favorite recipe")
                    }
                    if recipe.generatedByAI {
                        Label("AI", systemImage: "sparkles")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(StudioTheme.accent, in: Capsule())
                    }
                    Spacer()
                }

                Text(primaryStats)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(spacing: 6) {
                    Image(systemName: recipe.brewStyle == .iced ? "snowflake" : "sun.max.fill")
                    Text(recipe.brewStyle == .iced ? "Iced pour-over" : "Hot pour-over")
                    if recipe.brewStyle == .iced, recipe.iceGrams > 0 {
                        Text("·")
                        Text("\(recipe.iceGrams) g ice")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(styleTint)

                Text(sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.35))
        }
        .contentShape(Rectangle())
    }

    private var styleTint: Color {
        recipe.brewStyle == .iced ? StudioTheme.iced : StudioTheme.crema
    }

    private var primaryStats: String {
        "1:\(compactNumber(recipe.ratio)) · \(compactNumber(recipe.dose)) g · \(recipe.totalWater) ml"
    }

    private func patternName(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "centred pour"
        case .circular: "circular pour"
        case .spiral: "spiral pour"
        }
    }

    private func compactNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var sourceTitle: String {
        let source = [recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · ")
        return source.isEmpty ? "Saved on this iPhone" : source
    }
}
