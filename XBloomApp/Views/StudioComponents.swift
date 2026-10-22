import SwiftUI
import XBloomCore
#if canImport(UIKit)
import UIKit
#endif

struct StudioTextField: View {
    let title: String
    @Binding var text: String
    var icon: String?
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            TextField(title, text: $text, axis: axis)
                .font(.body.weight(.medium))
                .textFieldStyle(.plain)
                .padding(14)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
        }
    }
}

struct StudioValueStepper: View {
    let title: String
    let value: String
    let icon: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            HStack {
                Text(value)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    stepButton("minus", action: decrement)
                    stepButton("plus", action: increment)
                }
            }
        }
        .padding(14)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Shared identity card for a bean and its recipe collection.
struct BeanLibraryHeader: View {
    let name: String
    let roaster: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: StudioSymbol.bean)
                .font(.largeTitle)
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 74, height: 74)
                .background(.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("COFFEE LIBRARY")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.black.opacity(0.5))
                Text(name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                Text(roaster.isEmpty ? "Roaster not provided" : roaster)
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
}

/// Consistent stock presentation on both the bean shelf and recipe collections.
struct BagInventorySummary: View {
    let remainingGrams: Double
    let totalGrams: Double
    private var total: Double { totalGrams.isFinite ? max(1, totalGrams) : 250 }
    private var remaining: Double { remainingGrams.isFinite ? max(0, min(remainingGrams, total)) : 0 }

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Label("Bag remaining", systemImage: StudioSymbol.weight)
                    .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.muted)
                Spacer(minLength: 8)
                Text(String(format: "%.0f g", remaining))
                    .font(.headline.monospacedDigit()).foregroundStyle(.white)
                Text("· \(Int((remaining / total * 100).rounded()))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(StudioTheme.inventory)
            }
            BagInventoryProgress(remainingGrams: remaining, totalGrams: total)
        }
    }
}

struct BagInventoryProgress: View {
    let remainingGrams: Double
    let totalGrams: Double
    private var fraction: Double {
        guard remainingGrams.isFinite, totalGrams.isFinite, totalGrams > 0 else { return 0 }
        return min(1, max(0, remainingGrams / totalGrams))
    }
    var body: some View {
        ProgressView(value: fraction)
            .tint(StudioTheme.inventory)
            .accessibilityLabel("Bag remaining")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
