/// Tracks saves that happened after a sync began. Finishing an older upload
/// cannot label newer local edits as synced.
public struct LibrarySyncState: Equatable, Sendable {
    public private(set) var localRevision = 1
    public private(set) var syncedRevision = 0
    public var hasPendingChanges: Bool { localRevision > syncedRevision }
    public init() {}
    public mutating func recordLocalSave() { localRevision += 1 }
    public mutating func acknowledge(revision: Int) {
        syncedRevision = max(syncedRevision, min(revision, localRevision))
    }
}
