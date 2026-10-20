import Foundation

/// A light/dark pair of hex colours, already resolved by the server.
package struct ColorPair: Codable, Hashable, Sendable {
    package var light: String
    package var dark: String

    package init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }
}

/// A board status as `/sdk/config` describes it. Label, order and colour are the server's;
/// the SDK keeps no table of its own.
package struct RemoteStatus: Decodable, Hashable, Sendable, Identifiable {
    package enum Category: String, Sendable {
        case open, progress, closed

        var order: Int {
            switch self {
            case .open: return 0
            case .progress: return 1
            case .closed: return 2
            }
        }
    }

    package let slug: String
    package let label: String
    package let category: Category
    package let position: Int
    package let color: ColorPair?

    package var id: String { slug }

    package init(slug: String, label: String, category: Category, position: Int, color: ColorPair?) {
        self.slug = slug
        self.label = label
        self.category = category
        self.position = position
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case slug, label, category, position, color }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        label = (try? c.decode(String.self, forKey: .label)) ?? slug
        category = (try? c.decode(String.self, forKey: .category)).flatMap(Category.init(rawValue:)) ?? .open
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
        color = try? c.decode(ColorPair.self, forKey: .color)
    }
}

/// A board the key may show, as `/sdk/config` lists it: the in-app hub builds its sections
/// from these.
package struct SDKBoard: Decodable, Equatable, Sendable, Identifiable {
    package let id: String
    package let title: String
    package let boardType: String?
    package let isPublic: Bool
    package let statuses: [RemoteStatus]

    package init(id: String, title: String, boardType: String?, isPublic: Bool = true, statuses: [RemoteStatus]) {
        self.id = id
        self.title = title
        self.boardType = boardType
        self.isPublic = isPublic
        self.statuses = statuses
    }

    /// Both vocabularies the backend stores: ours (`bugs_fixes`) and the older one (`bug`).
    package var isBugs: Bool { boardType == "bugs_fixes" || boardType == "bug" }

    enum CodingKeys: String, CodingKey { case id, title, boardType = "board_type", isPublic = "is_public", statuses }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        boardType = try? c.decode(String.self, forKey: .boardType)
        isPublic = (try? c.decode(Bool.self, forKey: .isPublic)) ?? true
        statuses = ((try? c.decode([Lossy<RemoteStatus>].self, forKey: .statuses)) ?? [])
            .compactMap(\.value)
            .sorted { ($0.category.order, $0.position) < ($1.category.order, $1.position) }
    }
}

/// What the admin designed in the dashboard's "In-app experience": which sections, in what
/// order, under which labels, how users move between them, and how the roadmap is fed.
///
/// Every field falls back on its own: a style this version does not know reads as `auto`, an
/// unknown section kind is dropped — a version already on the App Store never breaks on a
/// layout the dashboard learns to write later.
package struct HubLayout: Decodable, Equatable, Sendable {
    package enum Style: String, Sendable { case auto, bar, chips, menu, home }

    package struct Section: Decodable, Equatable, Sendable {
        package enum Kind: String, Sendable { case board, roadmap, chat }
        package let id: String
        package let kind: Kind
        package let label: String
        package let enabled: Bool

        package init(id: String, kind: Kind, label: String = "", enabled: Bool = true) {
            self.id = id
            self.kind = kind
            self.label = label
            self.enabled = enabled
        }

        enum CodingKeys: String, CodingKey { case id, kind, label, enabled }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            guard let kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown section kind")
            }
            self.kind = kind
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        }
    }

    package struct Column: Decodable, Equatable, Sendable {
        package let id: String
        package let label: String
        package let statuses: [String]

        package init(id: String, label: String, statuses: [String]) {
            self.id = id
            self.label = label
            self.statuses = statuses
        }
    }

    package var style: Style
    package var title: String
    package var sections: [Section]
    package var columns: [Column]
    package var showVotes: Bool
    package var showVersion: Bool
    /// Entry ids in the admin's hand order for the roadmap. Cards not listed follow, by votes.
    package var order: [String]
    /// A team roadmap to show instead of the status columns. Nil: by status.
    package var roadmapID: String?

    package init(
        style: Style = .auto,
        title: String = "",
        sections: [Section] = [],
        columns: [Column] = HubLayout.defaultColumns,
        showVotes: Bool = true,
        showVersion: Bool = true,
        order: [String] = [],
        roadmapID: String? = nil
    ) {
        self.style = style
        self.title = title
        self.sections = sections
        self.columns = columns
        self.showVotes = showVotes
        self.showVersion = showVersion
        self.order = order
        self.roadmapID = roadmapID
    }

    /// The same three columns the dashboard starts from.
    package static let defaultColumns: [Column] = [
        Column(id: "next", label: "Planned", statuses: ["planned", "confirmed"]),
        Column(id: "now", label: "In progress", statuses: ["in_progress", "known_issue"]),
        Column(id: "shipped", label: "Shipped", statuses: ["completed", "fixed"]),
    ]

    enum CodingKeys: String, CodingKey { case style, title, sections, roadmap }
    enum RoadmapKeys: String, CodingKey { case columns, showVotes, showVersion, order, roadmapID = "roadmapId" }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decode(String.self, forKey: .style)).flatMap(Style.init(rawValue:)) ?? .auto
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        sections = ((try? c.decode([Lossy<Section>].self, forKey: .sections)) ?? []).compactMap(\.value)
        if let roadmap = try? c.nestedContainer(keyedBy: RoadmapKeys.self, forKey: .roadmap) {
            let decoded = ((try? roadmap.decode([Lossy<Column>].self, forKey: .columns)) ?? []).compactMap(\.value)
            columns = decoded.isEmpty ? HubLayout.defaultColumns : decoded
            showVotes = (try? roadmap.decode(Bool.self, forKey: .showVotes)) ?? true
            showVersion = (try? roadmap.decode(Bool.self, forKey: .showVersion)) ?? true
            order = ((try? roadmap.decode([Lossy<String>].self, forKey: .order)) ?? []).compactMap(\.value)
            roadmapID = (try? roadmap.decode(String.self, forKey: .roadmapID)).flatMap { $0.isEmpty ? nil : $0 }
        } else {
            columns = HubLayout.defaultColumns
            showVotes = true
            showVersion = true
            order = []
            roadmapID = nil
        }
    }
}

/// `GET /sdk/config`: theme, behaviour, copy and statuses for this app key.
///
/// Every field is optional in practice. Unknown keys are ignored, unknown enum values fall
/// back to the default, and a missing section is the default section — the SDK paints with
/// `fallback` before the network answers, and with whatever part of the config it could read
/// after.
package struct SDKConfig: Decodable, Equatable, Sendable {
    package enum SortOrder: String, Sendable { case votes, recent }
    package enum EmailField: String, Sendable { case none, optional, required }
    package enum Tab: String, Sendable, Hashable, CaseIterable { case open, done, mine }

    package struct Behaviour: Equatable, Sendable {
        package var allowVoteUndo = true
        package var showVoteCount = true
        package var showCommentCount = true
        package var submitEnabled = true
        /// Forced on by the server on the plans that carry the badge; the SDK obeys and offers no switch.
        package var poweredByFeeqd = false
        package var emailField: EmailField = .none
        package var defaultSort: SortOrder = .votes
        package var tabs: [Tab] = [.open, .done]
        /// Nil until the admin saves an in-app experience: then the hub is the key's first board.
        package var layout: HubLayout?

        package init() {}
    }

    package var schemaVersion: Int
    package var colors: [String: ColorPair]
    package var cornerRadius: Double?
    package var behaviour: Behaviour
    package var strings: [String: [String: String]]
    package var boardID: String?
    package var statuses: [RemoteStatus]
    /// Every board the key may show, in the key's order. Empty from a backend that predates it.
    package var boards: [SDKBoard]
    /// False once the team's plan has no room for another request: the SDK stops offering to
    /// send one. True from a backend that predates it.
    package var acceptingEntries = true
    /// The same for opening a new chat. A conversation already open goes on either way.
    package var acceptingConversations = true

    /// What the SDK paints with before — or without — a network round trip.
    package static let fallback = SDKConfig(
        schemaVersion: 1, colors: [:], cornerRadius: nil, behaviour: Behaviour(), strings: [:], boardID: nil, statuses: []
    )

    /// This config as one board sees it: that board's statuses instead of the first board's.
    package func scoped(to boardID: String) -> SDKConfig {
        guard let board = boards.first(where: { $0.id == boardID }) else { return self }
        var copy = self
        copy.boardID = boardID
        copy.statuses = board.statuses
        return copy
    }

    package init(
        schemaVersion: Int,
        colors: [String: ColorPair],
        cornerRadius: Double?,
        behaviour: Behaviour,
        strings: [String: [String: String]],
        boardID: String?,
        statuses: [RemoteStatus],
        boards: [SDKBoard] = []
    ) {
        self.schemaVersion = schemaVersion
        self.colors = colors
        self.cornerRadius = cornerRadius
        self.behaviour = behaviour
        self.strings = strings
        self.boardID = boardID
        self.statuses = statuses
        self.boards = boards
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", theme, behaviour, strings, boardID = "board_id", statuses, boards
        case acceptingEntries = "accepting_entries", acceptingConversations = "accepting_conversations"
    }

    enum ThemeKeys: String, CodingKey { case colors, cornerRadius }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        boardID = try? c.decode(String.self, forKey: .boardID)
        strings = (try? c.decode([String: [String: String]].self, forKey: .strings)) ?? [:]
        statuses = ((try? c.decode([Lossy<RemoteStatus>].self, forKey: .statuses)) ?? [])
            .compactMap(\.value)
            .sorted { ($0.category.order, $0.position) < ($1.category.order, $1.position) }
        if let theme = try? c.nestedContainer(keyedBy: ThemeKeys.self, forKey: .theme) {
            colors = ((try? theme.decode([String: Lossy<ColorPair>].self, forKey: .colors)) ?? [:]).compactMapValues(\.value)
            cornerRadius = try? theme.decode(Double.self, forKey: .cornerRadius)
        } else {
            colors = [:]
            cornerRadius = nil
        }
        behaviour = (try? c.decode(Behaviour.self, forKey: .behaviour)) ?? Behaviour()
        boards = ((try? c.decode([Lossy<SDKBoard>].self, forKey: .boards)) ?? []).compactMap(\.value)
        acceptingEntries = (try? c.decode(Bool.self, forKey: .acceptingEntries)) ?? true
        acceptingConversations = (try? c.decode(Bool.self, forKey: .acceptingConversations)) ?? true
    }
}

extension SDKConfig.Behaviour: Decodable {
    enum CodingKeys: String, CodingKey {
        case allowVoteUndo, showVoteCount, showCommentCount, submitEnabled, poweredByFeeqd, emailField, defaultSort, tabs, layout
    }

    package init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Bool.self, forKey: .allowVoteUndo) { allowVoteUndo = value }
        if let value = try? c.decode(Bool.self, forKey: .showVoteCount) { showVoteCount = value }
        if let value = try? c.decode(Bool.self, forKey: .showCommentCount) { showCommentCount = value }
        if let value = try? c.decode(Bool.self, forKey: .submitEnabled) { submitEnabled = value }
        if let value = try? c.decode(Bool.self, forKey: .poweredByFeeqd) { poweredByFeeqd = value }
        if let value = (try? c.decode(String.self, forKey: .emailField)).flatMap(SDKConfig.EmailField.init(rawValue:)) {
            emailField = value
        }
        if let value = (try? c.decode(String.self, forKey: .defaultSort)).flatMap(SDKConfig.SortOrder.init(rawValue:)) {
            defaultSort = value
        }
        if let raw = try? c.decode([String].self, forKey: .tabs) {
            let parsed = raw.compactMap(SDKConfig.Tab.init(rawValue:))
            if !parsed.isEmpty { tabs = parsed }
        }
        layout = try? c.decode(HubLayout.self, forKey: .layout)
    }
}
