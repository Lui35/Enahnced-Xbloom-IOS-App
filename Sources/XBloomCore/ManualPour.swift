import Foundation

/// A single pour driven straight from the app, with no recipe behind it.
///
/// It is sent as a one-step, grinder-off recipe rather than through the
/// vendor's direct brewer opcodes (`4506 brewer_begin`, `4510
/// brewer_temperature`, `4504`/`4505` pattern). Those opcodes exist in the
/// vendor's command table, but nothing has established what their payloads look
/// like — and they open a valve on a tank of near-boiling water. The recipe
/// path carries exactly the same four settings, and its encoding has been
/// verified against a recorded brew, so this asks the machine to do something
/// it has already demonstrably understood.
public struct ManualPour: Equatable, Sendable, Codable {
    public var volume: Int
    public var temperature: Int
    public var flowRate: Double
    public var pattern: PourPattern
    public var agitation: Bool

    public init(
        volume: Int = 60,
        temperature: Int = 93,
        flowRate: Double = 3.2,
        pattern: PourPattern = .spiral,
        agitation: Bool = false
    ) {
        self.volume = volume
        self.temperature = temperature
        self.flowRate = flowRate
        self.pattern = pattern
        self.agitation = agitation
    }

    public static let volumeRange = 10...240
    public static let temperatureRange = 80...96
    public static let flowRateRange = 3.0...3.5

    /// Roughly how long the pour itself will take, before any drawdown.
    public var estimatedDuration: TimeInterval {
        Double(max(0, volume)) / max(0.1, flowRate)
    }

    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !Self.volumeRange.contains(volume) {
            issues.append(
                .init(
                    field: "volume",
                    message: "Pour volume must be \(Self.volumeRange.lowerBound)–\(Self.volumeRange.upperBound) ml."
                )
            )
        }
        if !Self.temperatureRange.contains(temperature) {
            issues.append(
                .init(
                    field: "temperature",
                    message: "Temperature must be \(Self.temperatureRange.lowerBound)–\(Self.temperatureRange.upperBound) °C."
                )
            )
        }
        if !Self.flowRateRange.contains(flowRate) {
            issues.append(.init(field: "flowRate", message: "Flow must be 3.0–3.5 ml/s."))
        }
        return issues
    }

    /// The equivalent one-step recipe, so the pour travels the same encoding
    /// path a normal brew does.
    public var asRecipe: Recipe {
        Recipe(
            name: "Manual pour",
            grindSize: 50,
            dose: Self.bypassDose,
            useGrinder: false,
            pours: [
                PourStep(
                    volume: volume,
                    temperature: temperature,
                    flowRate: flowRate,
                    pauseBefore: 0,
                    pauseAfter: 0,
                    pattern: pattern,
                    agitationBefore: agitation,
                    agitationAfter: false
                )
            ]
        )
    }

    /// The bypass command carries a bean weight even when the grinder is not
    /// used. A zero there is suspected of making the machine reject the
    /// program, so this matches the value from a capture that brewed correctly.
    public static let bypassDose: Double = 15
}
