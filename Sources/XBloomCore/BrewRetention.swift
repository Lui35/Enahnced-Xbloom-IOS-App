import Foundation

/// How much brew history is worth keeping.
///
/// Every brew carries its telemetry samples — four readings a second for the
/// length of the extraction — so history is by far the largest thing the app
/// stores, on the phone and in the cloud alike. The recent ones are what the
/// app actually uses: the last brew of a recipe, a bean's recent cups, the
/// yield curve you compare against. A cup from six bags ago is weight.
public enum BrewRetention {
    /// Brews kept, newest first. A bag rarely outlives twenty cups, so this
    /// keeps every brew that could still be compared against the coffee in
    /// front of you.
    public static let limit = 20

    /// The brews to drop, given every brew's id and completion date.
    ///
    /// Ties are broken by id so two brews recorded in the same instant cannot
    /// produce a different answer on two devices, which would have them
    /// deleting each other's records forever.
    public static func idsToPrune(
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
