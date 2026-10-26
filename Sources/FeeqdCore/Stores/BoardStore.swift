import Combine
import Foundation

/// The board screen's state: config, pages, own votes, search.
///
/// Main-actor bound so SwiftUI reads it directly; the network work happens in `FeeqdClient`.
@MainActor
package final class BoardStore: ObservableObject {
    package enum Phase: Equatable {
        case idle, loading, loaded
        case failed(FeeqdError)
    }

    @Published package private(set) var phase: Phase = .idle
    @Published package private(set) var config: SDKConfig
    @Published package private(set) var entries: [Entry] = []
    @Published package private(set) var votedIDs: Set<String> = []
    /// What this device sent, public or not: the "Mine" tab, and the source of the requests
    /// only their author sees, which the list shows on top.
    @Published package private(set) var mine: [Entry] = []
    /// Requests opened from outside the list (a roadmap card) that its loaded pages don't hold:
    /// their detail still reads, votes and counts like any other.
    @Published package private(set) var opened: [String: Entry] = [:]
    @Published package private(set) var isLoadingMore = false
    @Published package private(set) var query = ""
    /// A failed vote, comment or page: shown once, never replacing content already on screen.
    @Published package var lastActionError: FeeqdError?

    package let client: FeeqdClient
    package private(set) var boardID: String?
    private let preferredBoardID: String?
    private let pageSize: Int
    private var pagination: Pagination?
    private var votesInFlight: Set<String> = []

    /// Pages are as big as the reader serves (200): the Open / Done tabs split what is loaded, so
    /// one page holding the whole board is what makes their counts exact on almost every app.
    package init(client: FeeqdClient, preferredBoardID: String? = nil, initialConfig: SDKConfig = .fallback, pageSize: Int = 200) {
        self.client = client
        self.preferredBoardID = preferredBoardID
        // Known before the first load: a detail opened from elsewhere (the roadmap) needs it.
        self.boardID = preferredBoardID
        self.config = initialConfig
        self.pageSize = pageSize
    }

    package var hasMore: Bool { pagination?.hasNext ?? false }

    /// Never loaded, or the last load failed. A load cut short when the user switched section
    /// ends as `.failed`: coming back to the board has to try again, not keep the error.
    package var needsLoad: Bool {
        switch phase {
        case .idle, .failed: return true
        case .loading, .loaded: return false
        }
    }

    /// "Mine" shows once this device has sent something: never an empty tab.
    package var visibleTabs: [SDKConfig.Tab] {
        config.behaviour.tabs.filter { $0 != .mine || !mine.isEmpty }
    }

    package func status(for slug: String) -> RemoteStatus? {
        config.statuses.first { $0.slug == slug }
    }

    package func entry(id: String) -> Entry? {
        entries.first { $0.id == id } ?? opened[id]
    }

    /// Keeps a request opened from elsewhere, so its detail can vote before, or without, the
    /// board's list loading.
    package func open(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }), opened[entry.id] == nil else { return }
        opened[entry.id] = entry
    }

    /// How many requests a tab holds, and whether that is all of them: past the first page the
    /// rest of the board is not loaded yet, so the count is a floor ("200+").
    package func count(in tab: SDKConfig.Tab) -> (count: Int, isComplete: Bool) {
        (entries(in: tab).count, tab == .mine || !hasMore)
    }

    /// There is no status filter on the list endpoint yet (spec H5), so tabs filter what is loaded.
    package func entries(in tab: SDKConfig.Tab?) -> [Entry] {
        guard let tab else { return entries }
        if tab == .mine { return mine }
        return entries.filter { entry in
            let category = status(for: entry.state)?.category ?? .open
            switch tab {
            case .open: return category != .closed
            case .done: return category == .closed
            case .mine: return false
            }
        }
    }

    // MARK: Loading

    /// Only the theme and copy, for a screen that shows no board (the chat on its own).
    /// A failure keeps the fallback: the chat still works, in the system's colours.
    package func loadConfig() async {
        if let resolved = try? await client.config() { config = resolved }
    }

    /// Cold start: config, first page and own votes. When the integrator named the board the
    /// three go out at once; otherwise the board comes from the config.
    ///
    /// `my-votes` is also what tells the dashboard the app launched: an authenticated SDK call
    /// registers the device. Its failure never fails the list.
    package func load() async {
        if entries.isEmpty { phase = .loading }
        do {
            if let preferred = preferredBoardID {
                async let fetchedConfig = client.config()
                async let firstPage = fetchPage(board: preferred, page: 1)
                async let votes = fetchVotes(board: preferred)
                async let own = fetchMine(board: preferred)
                let resolved = try await fetchedConfig
                mine = await own
                apply(try await firstPage, replacing: true)
                if let fetched = await votes { votedIDs = fetched }
                config = resolved.scoped(to: preferred)
                boardID = preferred
            } else {
                let resolved = try await client.config()
                guard let board = resolved.boardID else { throw FeeqdError.noBoard }
                config = resolved.scoped(to: board)
                boardID = board
                async let firstPage = fetchPage(board: board, page: 1)
                async let votes = fetchVotes(board: board)
                async let own = fetchMine(board: board)
                mine = await own
                apply(try await firstPage, replacing: true)
                if let fetched = await votes { votedIDs = fetched }
            }
            phase = .loaded
            await loadRest()
        } catch {
            if FeeqdError.isCancellation(error) {
                // Back to where the screen loads again when it returns.
                phase = entries.isEmpty ? .idle : .loaded
                return
            }
            let wrapped = FeeqdError.wrap(error)
            if entries.isEmpty {
                phase = .failed(wrapped)
            } else {
                phase = .loaded
                lastActionError = wrapped
            }
        }
    }

    /// Loads the next page when `entry` is the last row the screen shows. That is the last row of
    /// the TAB, not of everything loaded: in Open, the board's last loaded row may be a Done one
    /// that never appears, and the next page would never come.
    package func loadMoreIfNeeded(current entry: Entry, in tab: SDKConfig.Tab? = nil) async {
        guard tab != .mine, entry.id == entries(in: tab).last?.id else { return }
        await loadMore()
    }

    /// Boards up to this size are loaded whole, so the Open / Done counts are exact.
    private static let wholeBoardLimit = 1_000

    /// After the first page is on screen, the rest of the board, page by page, while it stays
    /// small enough to hold. A failed page stops quietly: scrolling still loads it later.
    private func loadRest() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        while hasMore, query.isEmpty, entries.count < Self.wholeBoardLimit, let board = boardID, !Task.isCancelled {
            guard let next = try? await fetchPage(board: board, page: (pagination?.page ?? 1) + 1) else { return }
            apply(next, replacing: false)
        }
    }

    /// The next page, whatever is on screen: a tab with no rows loaded yet has no last row to
    /// trigger `loadMoreIfNeeded`.
    package func loadMore() async {
        guard hasMore, !isLoadingMore, let board = boardID else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            apply(try await fetchPage(board: board, page: (pagination?.page ?? 1) + 1), replacing: false)
        } catch {
            if FeeqdError.isCancellation(error) { return }
            lastActionError = FeeqdError.wrap(error)
        }
    }

    package func search(_ text: String) async {
        let trimmed = text.feeqdTrimmed
        guard trimmed != query, let board = boardID else { return }
        query = trimmed
        do {
            apply(try await fetchPage(board: board, page: 1), replacing: true)
        } catch {
            // Typing on cancels the search before it: the next one is already on its way.
            if FeeqdError.isCancellation(error) { return }
            lastActionError = FeeqdError.wrap(error)
        }
    }

    // MARK: Votes

    /// Optimistic: the change is painted now and replaced by the server's count when it answers.
    /// On failure it is reverted. Retrying is safe — the backend only moves the count when the
    /// vote ledger changed.
    package func toggleVote(entryID: String) async {
        guard let board = boardID, let entry = entry(id: entryID), !entry.onlyYou,
              !votesInFlight.contains(entryID) else { return }
        let wasVoted = votedIDs.contains(entryID)
        if wasVoted && !config.behaviour.allowVoteUndo { return }

        votesInFlight.insert(entryID)
        defer { votesInFlight.remove(entryID) }
        setVote(entryID, voted: !wasVoted, delta: wasVoted ? -1 : 1)
        do {
            let result = wasVoted
                ? try await client.retractVote(boardID: board, entryID: entryID)
                : try await client.vote(boardID: board, entryID: entryID)
            if let index = entries.firstIndex(where: { $0.id == entryID }) { entries[index].voteCount = result.voteCount }
            opened[entryID]?.voteCount = result.voteCount
            if result.voted { votedIDs.insert(entryID) } else { votedIDs.remove(entryID) }
        } catch {
            setVote(entryID, voted: wasVoted, delta: wasVoted ? 1 : -1)
            lastActionError = FeeqdError.wrap(error)
        }
    }

    // MARK: Submitting

    package func submit(title: String, description: String) async throws -> SubmitReceipt {
        guard let board = boardID else { throw FeeqdError.noBoard }
        return try await client.submit(boardID: board, title: title, description: description)
    }

    /// A `202` carries no id, so the list is the only place a new request can appear. The
    /// worker needs a moment; this reloads once it has had it.
    package func reloadAfterSubmit(delay: UInt64 = 1_500_000_000) async {
        try? await Task.sleep(nanoseconds: delay)
        await load()
    }

    package func similar(to title: String) async -> [SimilarEntry] {
        guard let board = boardID else { return [] }
        return (try? await client.similar(boardID: board, title: title)) ?? []
    }

    // MARK: Private

    private func fetchPage(board: String, page: Int) async throws -> Page<Entry> {
        try await client.entries(
            boardID: board, page: page, pageSize: pageSize, sort: config.behaviour.defaultSort, query: query.isEmpty ? nil : query
        )
    }

    private func fetchVotes(board: String) async -> Set<String>? {
        try? await client.myVotes(boardID: board)
    }

    /// Quiet on failure, like the votes: an older backend has no such route.
    private func fetchMine(board: String) async -> [Entry] {
        (try? await client.mine(boardID: board)) ?? []
    }

    private func apply(_ page: Page<Entry>, replacing: Bool) {
        if replacing {
            // The author's requests nobody else sees go first, newest first, where they look for
            // what they just sent. Not while searching: search is the server's.
            let hidden = query.isEmpty ? mine.filter(\.onlyYou) : []
            let hiddenIDs = Set(hidden.map(\.id))
            entries = hidden + page.items.filter { !hiddenIDs.contains($0.id) }
        } else {
            let known = Set(entries.map(\.id))
            entries += page.items.filter { !known.contains($0.id) }
        }
        pagination = page.pagination
    }

    private func setVote(_ entryID: String, voted: Bool, delta: Int) {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].voteCount = max(0, entries[index].voteCount + delta)
        }
        if let count = opened[entryID]?.voteCount { opened[entryID]?.voteCount = max(0, count + delta) }
        if voted { votedIDs.insert(entryID) } else { votedIDs.remove(entryID) }
    }
}
