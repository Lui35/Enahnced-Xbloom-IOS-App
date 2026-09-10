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
            Label(title, systemImage: icon ?? "circle.fill")
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
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
