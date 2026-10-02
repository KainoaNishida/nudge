import Foundation

/// Tracks accepted queue changes. Ordering and wording alone never wake the pet.
public struct PetAttentionTracker {
    private var seenVersions: [String: String]?
    private var pendingVersions: [String: String] = [:]
    public var hasPendingChange: Bool { !pendingVersions.isEmpty }

    public init() {}

    /// The first observation establishes a baseline, so a relaunch does not
    /// announce old items as new. Call with every visible actionable thread.
    public mutating func observe(_ versions: [String: String], queueIsVisible: Bool) {
        pendingVersions = pendingVersions.filter { versions[$0.key] == $0.value }
        if let seenVersions {
            for (id, version) in versions where seenVersions[id] != version && !queueIsVisible {
                pendingVersions[id] = version
            }
        }
        seenVersions = versions
        if queueIsVisible { pendingVersions.removeAll() }
    }

    public mutating func acknowledge() { pendingVersions.removeAll() }

    public func shouldSignal(profile: UserProfile?, lastSignalAt: Date?, now: Date) -> Bool {
        guard hasPendingChange, let profile else { return false }
        return ManagedLifecycle.mayNotify(profile: profile, previous: lastSignalAt, now: now)
    }
}
