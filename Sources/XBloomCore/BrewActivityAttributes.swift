#if os(iOS)
import ActivityKit
import Foundation

public struct BrewActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: BrewProgramPhase
        public var stageTitle: String
        public var progress: Double
        public var currentPour: Int
        public var totalPours: Int
        public var waterML: Double
        public var targetWaterML: Int
        public var coffeeWeight: Double
        public var temperature: Double?
        public var elapsedSeconds: Int
        public var remainingSeconds: Int
        public var updatedAt: Date

        public init(
            phase: BrewProgramPhase,
            stageTitle: String,
            progress: Double,
            currentPour: Int,
            totalPours: Int,
            waterML: Double,
            targetWaterML: Int,
            coffeeWeight: Double,
            temperature: Double?,
            elapsedSeconds: Int,
            remainingSeconds: Int,
            updatedAt: Date = .now
        ) {
            self.phase = phase
            self.stageTitle = stageTitle
            self.progress = progress
            self.currentPour = currentPour
            self.totalPours = totalPours
            self.waterML = waterML
            self.targetWaterML = targetWaterML
            self.coffeeWeight = coffeeWeight
            self.temperature = temperature
            self.elapsedSeconds = elapsedSeconds
            self.remainingSeconds = remainingSeconds
            self.updatedAt = updatedAt
        }
    }

    public var recipeName: String
    public var machineName: String
    public var brewStyle: BrewStyle
    public var dose: Double

    public init(recipeName: String, machineName: String, brewStyle: BrewStyle, dose: Double) {
        self.recipeName = recipeName
        self.machineName = machineName
        self.brewStyle = brewStyle
        self.dose = dose
    }
}
#endif
