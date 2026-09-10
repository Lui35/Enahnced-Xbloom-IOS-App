import Foundation

/// Limits detailed telemetry while preserving brew summaries and maintenance history.
public enum BrewRetention {
    /// Most recent brews whose full telemetry is retained.
    public static let limit = 20

    /// Older brews whose samples can be cleared. Stable ties keep devices consistent.
    public static func idsToCompact(
        _ brews: [(id: UUID, completedAt: Date)],
        limit: Int = limit
    ) -> Set<UUID> {
        guard limit >= 0, brews.count > limit else { return [] }
        let ordered = brews.sorted {
            $0.completedAt == $1.completedAt
                ? $0.id.uuidString > $1.id.uuidString
                : $0.completedAt > $1.completedAt
        }
        return Set(ordered.dropFirst(limit).map(\.id))
    }
}
