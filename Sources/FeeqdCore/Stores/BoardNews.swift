import Foundation

/// When this user last had each board's list on screen, in the SDK's own UI. What came in after
/// is what the app's own entry point can badge (`Feeqd.boardStatus()`).
package struct BoardVisits {
    package static let key = "com.feeqd.feeqdkit.boardSeen"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` for a board this user never opened.
    package func lastSeen(_ boardID: String) -> Date? {
        (defaults.dictionary(forKey: Self.key)?[boardID] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// The visits of the boards opened at least once.
    package func lastSeen(_ boardIDs: [String]) -> [String: Date] {
        boardIDs.reduce(into: [:]) { $0[$1] = lastSeen($1) }
    }

    /// Never moves back: a list shown again with an older clock keeps the later visit.
    package func markSeen(_ boardID: String, at date: Date) {
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        if let previous = all[boardID] as? Double, previous >= date.timeIntervalSince1970 { return }
        all[boardID] = date.timeIntervalSince1970
        defaults.set(all, forKey: Self.key)
    }

    /// On sign-out: the next person on this install has not seen anything yet.
    package func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// How many public requests arrived since the user last looked, not counting their own.
package enum BoardNews {
    /// The newest page is all that is read: past this many, the count stops growing.
    package static let pageSize = 100

    /// The boards the hub shows, resolved the way the hub resolves them.
    package static func boardIDs(config: SDKConfig, preferredBoardID: String?) -> [String] {
        HubPlan.make(config: config, preferredBoardID: preferredBoardID).sections.compactMap(\.boardID)
    }

    /// `lastSeen` is `BoardVisits.lastSeen(_:)` of the boards: one never opened is not in it, and
    /// counts 0, not everything on it. Quiet on failure: no badge.
    package static func count(_ client: FeeqdClient, lastSeen: [String: Date]) async -> Int {
        var total = 0
        for (board, seen) in lastSeen {
            total += await count(client, boardID: board, since: seen)
        }
        return total
    }

    /// One request, newest first. `mine` only goes out when something is new, to leave out what
    /// this device sent (a request kept offline goes out later, after the visit).
    private static func count(_ client: FeeqdClient, boardID: String, since seen: Date) async -> Int {
        guard let page = try? await client.entries(boardID: boardID, page: 1, pageSize: pageSize, sort: .recent) else { return 0 }
        let fresh = page.items.filter { $0.createdAt > seen }
        guard !fresh.isEmpty else { return 0 }
        let own = Set(((try? await client.mine(boardID: boardID)) ?? []).map(\.id))
        return fresh.filter { !own.contains($0.id) }.count
    }
}
