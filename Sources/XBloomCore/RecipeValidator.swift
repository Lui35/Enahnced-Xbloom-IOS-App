import Foundation

public struct ValidationIssue: Error, Equatable, Identifiable, Sendable {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public var id: String { field + message }
    public let field: String
    public let message: String
    public let severity: Severity

    public init(field: String, message: String, severity: Severity = .error) {
        self.field = field
        self.message = message
        self.severity = severity
    }
}

public enum RecipeValidator {
    public static func validate(_ recipe: Recipe) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: "name", message: "Enter a recipe name."))
        }
        if !(5...30).contains(recipe.dose) {
            issues.append(.init(field: "dose", message: "Dose must be between 5 and 30 g."))
        }
        if !(1...80).contains(recipe.grindSize) {
            issues.append(.init(field: "grindSize", message: "Grind size must be between 1 and 80."))
        }
        if recipe.useGrinder, recipe.rpm == .off {
            issues.append(
                .init(
                    field: "rpm",
                    message: "This recipe grinds but has no grinder speed. "
                        + "It will run at \(recipe.programRPM.rawValue) RPM.",
                    severity: .warning
                )
            )
        }
        if recipe.pours.isEmpty || recipe.pours.count > 8 {
            issues.append(.init(field: "pours", message: "Use between 1 and 8 pour steps."))
        }
        if recipe.totalWater > 500 {
            issues.append(.init(field: "water", message: "Total machine water cannot exceed 500 ml."))
        }

        for (index, pour) in recipe.pours.enumerated() {
            let prefix = "pours[\(index)]"
            if !(0...240).contains(pour.volume) {
                issues.append(.init(field: "\(prefix).volume", message: "Pour volume must be 0–240 ml."))
            }
            if !(80...96).contains(pour.temperature) {
                issues.append(.init(field: "\(prefix).temperature", message: "Temperature must be 80–96°C."))
            }
            if !(3.0...3.5).contains(pour.flowRate) {
                issues.append(.init(field: "\(prefix).flowRate", message: "Flow must be 3.0–3.5 ml/s."))
            }
            if !(0...120).contains(pour.pauseBefore) || !(0...120).contains(pour.pauseAfter) {
                issues.append(.init(field: "\(prefix).pause", message: "Pauses must be 0–120 seconds."))
            }
        }

        let recommendedRatio: ClosedRange<Double> = recipe.brewStyle == .hot
            ? 14.5...18.5
            : 7.5...15
        if !recommendedRatio.contains(recipe.ratio) {
            issues.append(
                .init(
                    field: "ratio",
                    message: String(
                        format: "The 1:%.1f ratio is outside the recommended 1:%.1f–1:%.1f range.",
                        recipe.ratio,
                        recommendedRatio.lowerBound,
                        recommendedRatio.upperBound
                    ),
                    severity: .warning
                )
            )
        }
        return issues
    }

    public static func requireSafe(_ recipe: Recipe) throws {
        if let issue = validate(recipe).first(where: { $0.severity == .error }) {
            throw issue
        }
    }
}
