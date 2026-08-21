import Foundation

public struct BrewEstimate: Equatable, Sendable {
    public var water: Double
    public var stepIndex: Int
    public var phase: String
    public var complete: Bool
    public var totalTime: TimeInterval
}

public enum BrewProgramPhase: String, Codable, Equatable, Sendable {
    case preparing
    case grinding
    case blooming
    case pouring
    case resting
    case complete
    case error

    /// There used to be a `heating` case between grinding and the first pour.
    /// This machine has no such state: it never sends a heating event and
    /// never reports water temperature at all — `8108` did not appear once in
    /// a 1088-frame recording — so the phase was a guess the app made and then
    /// displayed as a machine reading. Once the grinder stops, the machine
    /// agitates and pours. Sessions saved by an older build still decode; they
    /// resume as `preparing`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BrewProgramPhase(rawValue: raw) ?? (raw == "heating" ? .preparing : .preparing)
    }
}

public struct BrewProgramEstimate: Equatable, Sendable {
    public var water: Double
    public var stepIndex: Int
    public var phase: BrewProgramPhase
    public var complete: Bool
    public var totalTime: TimeInterval
    public var extractionElapsed: TimeInterval
}

public enum BrewTimelineEventKind: String, Equatable, Sendable {
    case pour
    case rest
}

public struct BrewTimelineEvent: Equatable, Identifiable, Sendable {
    public var id: String
    public var elapsed: TimeInterval
    public var title: String
    public var pourIndex: Int
    public var kind: BrewTimelineEventKind

    public init(
        id: String,
        elapsed: TimeInterval,
        title: String,
        pourIndex: Int,
        kind: BrewTimelineEventKind
    ) {
        self.id = id
        self.elapsed = elapsed
        self.title = title
        self.pourIndex = pourIndex
        self.kind = kind
    }
}

public enum Brewing {
    /// Keeps a simulated brew short enough to preview while leaving enough
    /// real time to understand grinding, settling, every pour, and every rest.
    /// A normal pour-over lands around 60–120 seconds instead of a few seconds.
    public static func simulationWallDuration(
        for programDuration: TimeInterval
    ) -> TimeInterval {
        min(120, max(60, max(0, programDuration) * 0.5))
    }

    public static func estimate(recipe: Recipe, elapsed: TimeInterval) -> BrewEstimate {
        let totalTime = recipe.pours.reduce(0.0) {
            $0 + Double($1.volume) / $1.flowRate + Double($1.pauseAfter)
        }
        var cursor = max(0, elapsed)
        var water = 0.0

        for (index, pour) in recipe.pours.enumerated() {
            let pourTime = Double(pour.volume) / pour.flowRate
            if cursor < pourTime {
                return BrewEstimate(
                    water: water + cursor * pour.flowRate,
                    stepIndex: index,
                    phase: index == 0 ? "Blooming" : "Pouring",
                    complete: false,
                    totalTime: totalTime
                )
            }
            water += Double(pour.volume)
            cursor -= pourTime
            if cursor < Double(pour.pauseAfter) {
                return BrewEstimate(
                    water: water,
                    stepIndex: index,
                    phase: "Resting after pour",
                    complete: false,
                    totalTime: totalTime
                )
            }
            cursor -= Double(pour.pauseAfter)
        }

        return BrewEstimate(
            water: water,
            stepIndex: max(0, recipe.pours.count - 1),
            phase: "Complete",
            complete: true,
            totalTime: totalTime
        )
    }

    /// Positions pour and rest boundaries on the same clock used by live and
    /// simulated telemetry. Preparation is intentionally included so the
    /// first bloom can never appear while the machine is still grinding.
    public static func timelineEvents(
        recipe: Recipe,
        grindingDuration: TimeInterval = 22,
        settlingDuration: TimeInterval = 13
    ) -> [BrewTimelineEvent] {
        var cursor = (recipe.useGrinder ? max(0, grindingDuration) : 0) + max(0, settlingDuration)
        var events: [BrewTimelineEvent] = []

        for (index, pour) in recipe.pours.enumerated() {
            cursor += Double(max(0, pour.pauseBefore))
            let title = index == 0 ? "Bloom" : "P\(index + 1)"
            events.append(
                BrewTimelineEvent(
                    id: "pour-\(index)",
                    elapsed: cursor,
                    title: title,
                    pourIndex: index,
                    kind: .pour
                )
            )
            cursor += Double(max(0, pour.volume)) / max(0.1, pour.flowRate)
            if pour.pauseAfter > 0 {
                events.append(
                    BrewTimelineEvent(
                        id: "rest-\(index)",
                        elapsed: cursor,
                        title: "Rest",
                        pourIndex: index,
                        kind: .rest
                    )
                )
            }
            cursor += Double(max(0, pour.pauseAfter))
        }
        return events
    }

    /// The same pour and rest boundaries, but measured from the moment the
    /// machine starts the first pour rather than from the moment the recipe was
    /// sent. Live telemetry cannot know how long grinding will take on any
    /// given morning, so charts that mix machine readings with recipe markers
    /// have to share this zero or the markers drift away from the data.
    public static func extractionEvents(recipe: Recipe) -> [BrewTimelineEvent] {
        let events = timelineEvents(recipe: recipe, grindingDuration: 0, settlingDuration: 0)
        guard let first = events.first else { return [] }
        return events.map { event in
            var shifted = event
            shifted.elapsed = max(0, event.elapsed - first.elapsed)
            return shifted
        }
    }

    /// How long the pours themselves should take, from the start of the first
    /// pour to the end of the last rest. Preparation is excluded.
    public static func extractionDuration(recipe: Recipe) -> TimeInterval {
        recipe.pours.enumerated().reduce(0.0) { total, element in
            let (index, pour) = element
            let leadIn = index == 0 ? 0 : Double(max(0, pour.pauseBefore))
            let pourTime = Double(max(0, pour.volume)) / max(0.1, pour.flowRate)
            return total + leadIn + pourTime + Double(max(0, pour.pauseAfter))
        }
    }

    public static func deductDose(_ dose: Double, from bean: BeanProfile) -> BeanProfile {
        var result = bean
        result.remainingWeightGrams = max(0, bean.remainingWeightGrams - max(0, dose))
        return result
    }

    /// Estimates the complete machine workflow while keeping preparation time
    /// separate from extraction time. In particular, grinder time can never
    /// consume the bloom or first-pour rest.
    public static func estimateProgram(
        recipe: Recipe,
        elapsed: TimeInterval,
        grindingDuration: TimeInterval = 22,
        settlingDuration: TimeInterval = 10
    ) -> BrewProgramEstimate {
        let grinderTime = recipe.useGrinder ? max(0, grindingDuration) : 0
        let settleTime = max(0, settlingDuration)
        let extractionTime = recipe.pours.reduce(0.0) {
            $0 + Double($1.pauseBefore + $1.pauseAfter) + Double($1.volume) / max(0.1, $1.flowRate)
        }
        let totalTime = grinderTime + settleTime + extractionTime
        var cursor = max(0, elapsed)

        if cursor < grinderTime {
            return BrewProgramEstimate(
                water: 0,
                stepIndex: 0,
                phase: .grinding,
                complete: false,
                totalTime: totalTime,
                extractionElapsed: 0
            )
        }
        cursor -= grinderTime

        if cursor < settleTime {
            return BrewProgramEstimate(
                water: 0,
                stepIndex: 0,
                phase: .preparing,
                complete: false,
                totalTime: totalTime,
                extractionElapsed: 0
            )
        }
        cursor -= settleTime
        let extractionElapsed = cursor
        var water = 0.0

        for (index, pour) in recipe.pours.enumerated() {
            if cursor < Double(pour.pauseBefore) {
                return BrewProgramEstimate(
                    water: water,
                    stepIndex: index,
                    phase: .resting,
                    complete: false,
                    totalTime: totalTime,
                    extractionElapsed: extractionElapsed
                )
            }
            cursor -= Double(pour.pauseBefore)

            let pourTime = Double(pour.volume) / max(0.1, pour.flowRate)
            if cursor < pourTime {
                return BrewProgramEstimate(
                    water: water + cursor * pour.flowRate,
                    stepIndex: index,
                    phase: index == 0 ? .blooming : .pouring,
                    complete: false,
                    totalTime: totalTime,
                    extractionElapsed: extractionElapsed
                )
            }
            water += Double(pour.volume)
            cursor -= pourTime

            if cursor < Double(pour.pauseAfter) {
                return BrewProgramEstimate(
                    water: water,
                    stepIndex: index,
                    phase: .resting,
                    complete: false,
                    totalTime: totalTime,
                    extractionElapsed: extractionElapsed
                )
            }
            cursor -= Double(pour.pauseAfter)
        }

        return BrewProgramEstimate(
            water: water,
            stepIndex: max(0, recipe.pours.count - 1),
            phase: .complete,
            complete: true,
            totalTime: totalTime,
            extractionElapsed: extractionElapsed
        )
    }
}

/// Produces a stable, monotonic trend for live charts without altering the
/// raw scale and water readings saved in brew history.
public enum BrewGraphSmoother {
    public static func smooth(
        _ samples: [BrewSample],
        responseTime: TimeInterval = 0.85
    ) -> [BrewSample] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return samples }

        let timeConstant = max(0.05, responseTime)
        var previousElapsed = first.elapsed
        var displayedWater = max(0, first.water)
        var displayedWeight = max(0, first.coffeeWeight)
        var result = [
            BrewSample(
                elapsed: first.elapsed,
                water: displayedWater,
                coffeeWeight: displayedWeight,
                temperature: first.temperature
            )
        ]
        result.reserveCapacity(samples.count)

        for sample in samples.dropFirst() {
            let delta = max(0.01, sample.elapsed - previousElapsed)
            let blend = 1 - exp(-delta / timeConstant)
            let waterTarget = max(displayedWater, max(0, sample.water))
            let weightTarget = max(displayedWeight, max(0, sample.coffeeWeight))

            displayedWater += (waterTarget - displayedWater) * blend
            displayedWeight += (weightTarget - displayedWeight) * blend
            result.append(
                BrewSample(
                    elapsed: sample.elapsed,
                    water: displayedWater,
                    coffeeWeight: displayedWeight,
                    temperature: sample.temperature
                )
            )
            previousElapsed = sample.elapsed
        }

        return result
    }
}
