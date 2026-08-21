import Foundation

/// How the dose that was actually weighed sits against the one a recipe asks
/// for.
///
/// Coffee does not come out of the bag in exact grams, and the bag does not
/// always hold as much as the recipe wants. Missing the target is the normal
/// case, not a mistake, so nothing here decides whether a brew may start — the
/// range the machine will grind is the only hard stop. This says what the dose
/// does to the cup, so brewing a gram short is a choice made knowingly rather
/// than a dead end.
public enum DoseFit: String, Sendable, Equatable, CaseIterable {
    /// Nothing on the scale yet.
    case empty
    /// Short by more than a gram, but the cup is still recognisably the recipe.
    case short
    /// So short that the brew leaves the ratio range this style lives in.
    case thin
    /// Within a gram either way — the everyday case.
    case close
    /// As close as the machine's scale resolves.
    case onTarget
    /// More than a gram past the target. Coffee cannot be poured back out.
    case over

    /// The scale reports to a tenth of a gram, so anything inside this is the
    /// target as far as the machine can tell.
    public static let onTargetMargin = 0.15
    /// The gram either way a dose is expected to live inside. On a normal
    /// recipe it moves the ratio by well under a point.
    public static let workableMargin = 1.0
    /// Below this the pan is empty rather than lightly loaded.
    public static let emptyPanThreshold = 0.5

    public init(measured: Double, recipe: Recipe) {
        guard measured >= Self.emptyPanThreshold else {
            self = .empty
            return
        }
        let difference = measured - recipe.dose
        let gap = abs(difference)
        if gap <= Self.onTargetMargin {
            self = .onTarget
        } else if gap <= Self.workableMargin {
            self = .close
        } else if difference > 0 {
            self = .over
        } else {
            // Under by more than a gram is still brewable; how much weaker the
            // cup gets is what separates "a bit light" from a different drink,
            // and the ratio range validation already uses is the measure of it.
            let projected = recipe.ratio(atDose: measured)
            self = RecipeValidator.recommendedRatio(for: recipe.brewStyle).contains(projected)
                ? .short
                : .thin
        }
    }

    /// Whether the dose is the recipe's, near enough that the difference is
    /// only worth a note.
    public var isNominal: Bool { self == .onTarget || self == .close }
}
