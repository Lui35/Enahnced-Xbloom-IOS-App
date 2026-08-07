import Foundation

/// What a grind setting on the machine's 1–80 dial is actually good for.
///
/// The machine's own interface names a brewing method for each part of the
/// range, which is far more useful than a bare number when you are deciding
/// where to put the dial.
public struct GrindGuide: Equatable, Sendable, Identifiable {
    public let range: ClosedRange<Int>
    public let method: String
    public let detail: String

    public var id: Int { range.lowerBound }

    public init(range: ClosedRange<Int>, method: String, detail: String) {
        self.range = range
        self.method = method
        self.detail = detail
    }
}

public enum GrindSizeGuide {
    public static let bands: [GrindGuide] = [
        GrindGuide(range: 1...15, method: "Espresso", detail: "Finest"),
        GrindGuide(range: 16...30, method: "AeroPress", detail: "Medium-fine"),
        GrindGuide(range: 31...55, method: "Pour-over", detail: "Medium · V60 & Chemex"),
        GrindGuide(range: 56...80, method: "French press", detail: "Coarse · also cold brew"),
    ]

    public static let fullRange = 1...80

    public static func band(for size: Int) -> GrindGuide {
        let clamped = min(fullRange.upperBound, max(fullRange.lowerBound, size))
        return bands.first { $0.range.contains(clamped) } ?? bands[bands.count - 1]
    }

    /// The short label shown beside the dial, e.g. "Pour-over".
    public static func method(for size: Int) -> String {
        band(for: size).method
    }

    /// The method plus its texture, e.g. "Pour-over · Medium · V60 & Chemex".
    public static func description(for size: Int) -> String {
        let band = band(for: size)
        return "\(band.method) · \(band.detail)"
    }
}
