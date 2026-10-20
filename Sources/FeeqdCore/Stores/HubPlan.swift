import Foundation

/// One section of the in-app hub: a board, or the roadmap.
package struct HubSection: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case board(id: String, isBugs: Bool)
        case roadmap
    }

    package let id: String
    package let kind: Kind
    /// Empty means "use the SDK's own word" (Requests, Bugs, Roadmap), in the user's language.
    package let label: String

    package init(id: String, kind: Kind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    package var boardID: String? {
        if case let .board(id, _) = kind { return id }
        return nil
    }
}

/// What the hub shows, decided once from `/sdk/config`: the sections, how users move between
/// them, whether the chat is offered, and the roadmap's columns.
package struct HubPlan: Equatable, Sendable {
    /// How the sections are laid out, already resolved: `auto` never reaches the UI.
    package enum Style: String, Sendable { case single, bar, chips, menu, home }

    package var sections: [HubSection]
    package var style: Style
    package var title: String
    /// The admin's switch. The chat still only shows when the key carries it (`ChatStatus`).
    package var chatEnabled: Bool
    package var columns: [HubLayout.Column]
    package var showVotes: Bool
    package var showVersion: Bool
    /// The admin's hand order for roadmap cards; empty sorts by votes.
    package var order: [String] = []
    /// The team roadmap the admin picked for the app; nil groups every request by status.
    package var roadmapID: String?

    /// With no saved layout the hub is the key's first board, and no chat: the team turns the
    /// chat on in the dashboard once someone is there to answer. A chat nobody reads is worse
    /// than no chat.
    package static func make(config: SDKConfig, preferredBoardID: String?) -> HubPlan {
        let boards = config.boards
        let firstBoardID = preferredBoardID ?? config.boardID ?? boards.first?.id
        func boardSection(_ id: String, label: String) -> HubSection? {
            if let board = boards.first(where: { $0.id == id }) {
                // A board only the team sees cannot be read from the app: a section for it would
                // open on an error.
                guard board.isPublic else { return nil }
                return HubSection(id: id, kind: .board(id: id, isBugs: board.isBugs), label: label)
            }
            // A backend that predates `boards` still names its one board.
            if boards.isEmpty, id == firstBoardID {
                return HubSection(id: id, kind: .board(id: id, isBugs: false), label: label)
            }
            return nil
        }

        guard let layout = config.behaviour.layout, !layout.sections.isEmpty else {
            let only = firstBoardID.flatMap { boardSection($0, label: "") }
            return HubPlan(
                sections: only.map { [$0] } ?? [],
                style: .single,
                title: "",
                chatEnabled: false,
                columns: HubLayout.defaultColumns,
                showVotes: true,
                showVersion: true
            )
        }

        var sections: [HubSection] = []
        var chatEnabled = false
        for section in layout.sections where section.enabled {
            switch section.kind {
            case .board:
                if let resolved = boardSection(section.id, label: section.label) { sections.append(resolved) }
            case .roadmap:
                if !boards.isEmpty { sections.append(HubSection(id: "roadmap", kind: .roadmap, label: section.label)) }
            case .chat:
                chatEnabled = true
            }
        }
        // Every board switched off, or all of them gone: never an empty hub.
        if !sections.contains(where: { $0.boardID != nil }), let fallback = firstBoardID.flatMap({ boardSection($0, label: "") }) {
            sections.insert(fallback, at: 0)
        }

        return HubPlan(
            sections: sections,
            style: resolve(layout.style, sectionCount: sections.count),
            title: layout.title,
            chatEnabled: chatEnabled,
            columns: layout.columns,
            showVotes: layout.showVotes,
            showVersion: layout.showVersion,
            order: layout.order,
            roadmapID: layout.roadmapID
        )
    }

    /// The dashboard's preview makes the same call: 1 section has no switcher, 2–3 go in the
    /// bar, 4 or more become chips — unless the admin picked a style.
    package static func resolve(_ style: HubLayout.Style, sectionCount: Int) -> Style {
        if sectionCount <= 1 { return style == .home ? .home : .single }
        switch style {
        case .auto: return sectionCount <= 3 ? .bar : .chips
        case .bar: return .bar
        case .chips: return .chips
        case .menu: return .menu
        case .home: return .home
        }
    }
}

/// The roadmap: every board's entries, sorted into the admin's columns by status slug.
///
/// The public list has no status filter yet, so each board's first pages are read and
/// filtered here — fine for the few hundred entries an app's roadmap is built from.
@MainActor
package final class RoadmapStore: ObservableObject {
    package struct Item: Identifiable, Equatable {
        package let entry: Entry
        package let isBug: Bool
        package var id: String { entry.id }
    }

    package enum Phase: Equatable {
        case loading, loaded
        case failed(FeeqdError)
    }

    @Published package private(set) var phase: Phase = .loading
    @Published package private(set) var columns: [(column: HubLayout.Column, items: [Item])] = []

    private let client: FeeqdClient

    package init(client: FeeqdClient) {
        self.client = client
    }

    /// Lanes of a team roadmap: where each item's status says it is, the one grouping every
    /// board shares. The UI names them in the user's language by id.
    package static let teamRoadmapLanes: [HubLayout.Column] = [
        HubLayout.Column(id: "lane.open", label: "Planned", statuses: []),
        HubLayout.Column(id: "lane.progress", label: "In progress", statuses: []),
        HubLayout.Column(id: "lane.closed", label: "Done", statuses: []),
    ]

    package func load(
        boards: [SDKBoard],
        columns wanted: [HubLayout.Column],
        order: [String] = [],
        roadmapID: String? = nil
    ) async {
        // A retry shows it is trying: the error screen gives way to the spinner.
        if case .failed = phase { phase = .loading }
        if let roadmapID {
            await loadTeamRoadmap(roadmapID, boards: boards)
            return
        }
        // Hand-placed cards first, in the admin's order; the rest after them, most voted first.
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            var all: [Item] = []
            try await withThrowingTaskGroup(of: [Item].self) { group in
                for board in boards where board.isPublic {
                    group.addTask { [client] in
                        let page = try await client.entries(boardID: board.id, page: 1, pageSize: 100, sort: .votes)
                        return page.items.map { Item(entry: $0, isBug: board.isBugs) }
                    }
                }
                for try await items in group { all.append(contentsOf: items) }
            }
            columns = wanted.map { column in
                (column, all.filter { column.statuses.contains($0.entry.state) }.sorted { a, b in
                    let ra = rank[a.entry.id] ?? .max, rb = rank[b.entry.id] ?? .max
                    return ra != rb ? ra < rb : a.entry.voteCount > b.entry.voteCount
                })
            }
            phase = .loaded
        } catch {
            if FeeqdError.isCancellation(error) { return }
            phase = .failed(FeeqdError.wrap(error))
        }
    }


    private func loadTeamRoadmap(_ roadmapID: String, boards: [SDKBoard]) async {
        do {
            let entries = try await client.roadmapEntries(roadmapID: roadmapID)
            let byBoard = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
            func category(_ entry: Entry) -> RemoteStatus.Category {
                byBoard[entry.boardID]?.statuses.first { $0.slug == entry.state }?.category ?? .open
            }
            let items = entries.map { Item(entry: $0, isBug: byBoard[$0.boardID]?.isBugs ?? false) }
            let lanes: [RemoteStatus.Category] = [.open, .progress, .closed]
            columns = zip(Self.teamRoadmapLanes, lanes).map { lane, cat in
                (lane, items.filter { category($0.entry) == cat }.sorted { $0.entry.voteCount > $1.entry.voteCount })
            }
            phase = .loaded
        } catch {
            if FeeqdError.isCancellation(error) { return }
            phase = .failed(FeeqdError.wrap(error))
        }
    }
}
