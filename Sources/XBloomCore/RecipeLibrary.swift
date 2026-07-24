import Foundation

public enum RecipeLibrary {
    public static let defaults: [Recipe] = [
        Recipe(
            name: "Morning Bloom",
            roaster: "Onyx",
            origin: "Ethiopia · Natural",
            grindSize: 50,
            rpm: .rpm80,
            dose: 18,
            pours: [
                PourStep(volume: 50, temperature: 93, flowRate: 3, pauseBefore: 5, pauseAfter: 30),
                PourStep(volume: 119, temperature: 93, flowRate: 3.5, pauseAfter: 10),
                PourStep(volume: 119, temperature: 93, flowRate: 3.5),
            ]
        ),
        Recipe(
            name: "Citrus Study",
            roaster: "April",
            origin: "Kenya · Washed",
            grindSize: 48,
            rpm: .rpm80,
            dose: 18,
            pours: [
                PourStep(
                    volume: 55,
                    temperature: 92,
                    flowRate: 3,
                    pauseBefore: 5,
                    pauseAfter: 35,
                    pattern: .circular,
                    agitationAfter: true
                ),
                PourStep(volume: 110, temperature: 92, flowRate: 3.4, pauseAfter: 15),
                PourStep(volume: 105, temperature: 91, flowRate: 3.5),
            ]
        ),
        Recipe(
            name: "Soft Landing",
            roaster: "Sey",
            origin: "Colombia · Honey",
            grindSize: 55,
            rpm: .rpm70,
            dose: 17,
            pours: [
                PourStep(
                    volume: 50,
                    temperature: 90,
                    flowRate: 3,
                    pauseBefore: 5,
                    pauseAfter: 30,
                    pattern: .center,
                    agitationBefore: true
                ),
                PourStep(volume: 119, temperature: 90, flowRate: 3.3, pauseAfter: 10, pattern: .circular),
                PourStep(volume: 120, temperature: 89, flowRate: 3.4),
            ]
        ),
    ]
}
