import Foundation

package enum StringKey: String, CaseIterable, Sendable {
    case boardTitle = "board.title"
    case tabOpen = "tab.open"
    case tabDone = "tab.done"
    case searchPrompt = "search.prompt"
    case emptyTitle = "empty.title"
    case emptyMessage = "empty.message"
    case searchEmpty = "search.empty"
    case tabEmpty = "tab.empty"
    case errorTitle = "error.title"
    case errorMessage = "error.message"
    case errorRetry = "error.retry"
    case rateLimited = "error.rateLimited"
    case ok = "common.ok"
    case close = "common.close"
    case voteUpvote = "vote.upvote"
    case voteVoted = "vote.voted"
    case anonymousAuthor = "entry.anonymousAuthor"
    case commentsTitle = "comments.title"
    case commentsEmpty = "comments.empty"
    case entryOnlyYouHint = "entry.only_you_hint"
    case tabMine = "tab.mine"
    case sortTitle = "sort.title"
    case sortVotes = "sort.votes"
    case sortRecent = "sort.recent"
    case sortStatus = "sort.status"
    case listTop = "list.top"
    case commentPlaceholder = "comment.placeholder"
    case commentReplyPlaceholder = "comment.replyPlaceholder"
    case commentSend = "comment.send"
    case commentReply = "comment.reply"
    case commentTeam = "comment.team"
    case commentPinned = "comment.pinned"
    case commentPending = "comment.pending"
    case sendPending = "send.pending"
    case translateSee = "translate.see"
    case translateOriginal = "translate.original"
    case submitCTA = "submit.cta"
    case submitTitle = "submit.title"
    case submitTitlePlaceholder = "submit.titlePlaceholder"
    case submitDescriptionPlaceholder = "submit.descriptionPlaceholder"
    case submitSend = "submit.send"
    case submitCancel = "submit.cancel"
    case submitSimilar = "submit.similar"
    case submitSentTitle = "submit.sent.title"
    case submitSentMessage = "submit.sent.message"
    case submitKeptTitle = "submit.kept.title"
    case submitKeptMessage = "submit.kept.message"
    case submitDone = "submit.done"
    case submitAnonymousNotAllowed = "submit.anonymousNotAllowed"
    case submitQuotaExceeded = "submit.quotaExceeded"
    case submitClosed = "submit.closed"
    case submitBlocked = "submit.blocked"
    case submitDiscardTitle = "submit.discard.title"
    case submitDiscardConfirm = "submit.discard.confirm"
    case submitDiscardKeep = "submit.discard.keep"
    case poweredBy = "poweredBy"
    case chatTitle = "chat.title"
    case chatButton = "chat.button"
    case chatEmptyTitle = "chat.empty.title"
    case chatEmptyMessage = "chat.empty.message"
    case chatPlaceholder = "chat.placeholder"
    case chatSend = "chat.send"
    case chatTeam = "chat.team"
    case chatYou = "chat.you"
    case chatClosed = "chat.closed"
    case chatQuotaExceeded = "chat.quotaExceeded"
    case chatTooLong = "chat.tooLong"
    case chatUnread = "chat.unread"
    case reviewMessage = "review.message"
    case reviewTitle = "review.title"
    case reviewButton = "review.button"
    case sectionRequests = "hub.requests"
    case sectionBugs = "hub.bugs"
    case sectionRoadmap = "hub.roadmap"
    case homeTitle = "home.title"
    case homeSubtitle = "home.subtitle"
    case homeChat = "home.chat"
    case roadmapEmpty = "roadmap.empty"
    case roadmapFeature = "roadmap.feature"
    case roadmapLanePlanned = "roadmap.lane.planned"
    case roadmapLaneProgress = "roadmap.lane.progress"
    case roadmapLaneDone = "roadmap.lane.done"
    case roadmapBugFix = "roadmap.bugFix"
    case sections = "hub.sections"
    case statusPending = "status.pending"
    case statusInReview = "status.inReview"
    case statusPlanned = "status.planned"
    case statusInProgress = "status.inProgress"
    case statusCompleted = "status.completed"
    case statusDeclined = "status.declined"
    case statusReported = "status.reported"
    case statusConfirmed = "status.confirmed"
    case statusKnownIssue = "status.knownIssue"
    case statusFixing = "status.fixing"
    case statusFixed = "status.fixed"
    case statusCannotReproduce = "status.cannotReproduce"
}

/// Every string the SDK shows, and where it comes from.
///
/// Resolution, first match wins: the integrator's override in code → the dashboard's copy for
/// the user's locale (`es-MX`) → for its base language (`es`) → the bundled table for the
/// locale → for the base language → English. The bundled tables (BundledStrings.swift) are
/// complete in 17 languages, so the first launch without network still reads right.
package struct StringTable: Sendable {
    package let overrides: [String: String]
    package let remote: [String: [String: String]]
    package let languages: [String]

    package init(
        overrides: [String: String] = [:],
        remote: [String: [String: String]] = [:],
        languages: [String] = Locale.preferredLanguages
    ) {
        self.overrides = overrides
        self.remote = remote
        self.languages = languages
    }

    package func with(remote: [String: [String: String]]) -> StringTable {
        StringTable(overrides: overrides, remote: remote, languages: languages)
    }

    package func callAsFunction(_ key: StringKey) -> String {
        string(key.rawValue)
    }

    package func string(_ key: String) -> String {
        if let value = overrides[key] { return value }
        let tags = candidates
        for tag in tags { if let value = remote[tag]?[key] { return value } }
        for tag in tags { if let value = Self.bundled[tag]?[key] { return value } }
        return Self.bundled["en"]?[key] ?? key
    }

    /// A name the team wrote for the user's language (or the integrator in code), and nothing
    /// otherwise: for names with no bundled text, like a tab's, that fall back to something else.
    package func custom(_ key: String) -> String? {
        if let value = overrides[key], !value.isEmpty { return value }
        for tag in candidates {
            if let value = remote[tag]?[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return nil
    }

    /// The team's message over the list: theirs for the user's language, then their English one,
    /// as every other text falls back to English. It has no bundled text: left empty, the app
    /// shows nothing.
    package var listNote: String? {
        let key = "list.note"
        let note = custom(key) ?? remote["en"]?[key]
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }

    /// What a review request reads as. The dashboard sends the team's saved message in the
    /// user's language when it knows it, and in English when it does not (a reply on a request).
    /// While the text is one of the saved or bundled review messages, in any language, the user
    /// reads the one for their language; anything the team typed by hand stays as it is.
    package func reviewMessage(_ body: String) -> String {
        let sent = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = StringKey.reviewMessage.rawValue
        let known = remote.values.compactMap { $0[key]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            + Self.bundled.values.compactMap { $0[key] }
        guard !sent.isEmpty, known.contains(sent) else { return body }
        return self(.reviewMessage)
    }

    /// The names Feeqd gives a new board's statuses. One still called this was never renamed,
    /// so the app names it in the user's language; a renamed one keeps the team's name.
    private static let stockStatuses: [String: StringKey] = [
        "Pending": .statusPending,
        "In review": .statusInReview,
        "Planned": .statusPlanned,
        "In progress": .statusInProgress,
        "Completed": .statusCompleted,
        "Declined": .statusDeclined,
        "Reported": .statusReported,
        "Confirmed": .statusConfirmed,
        "Known issue": .statusKnownIssue,
        "Fixing": .statusFixing,
        "Fixed": .statusFixed,
        "Cannot reproduce": .statusCannotReproduce,
    ]

    /// A status's name for the user: translated while it is Feeqd's own, the team's otherwise,
    /// and its slug made readable when the board does not know it.
    package func status(_ label: String?, slug: String) -> String {
        guard let label, !label.isEmpty else { return slug.replacingOccurrences(of: "_", with: " ").capitalized }
        guard let key = Self.stockStatuses[label] else { return label }
        return self(key)
    }

    /// `zh-Hans-US` → `zh-Hans-US`, `zh_Hans_US`, `zh-Hans`, `zh`: remote tables are keyed by
    /// whatever the dashboard saved, and a script (`zh-Hans`) sits between the region and the base.
    private var candidates: [String] {
        languages.flatMap { tag -> [String] in
            let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            guard !parts.isEmpty else { return [tag] }
            let prefixes = (1..<parts.count).reversed().map { parts.prefix($0).joined(separator: "-") }
            return [tag, tag.replacingOccurrences(of: "-", with: "_")] + prefixes
        }
    }

    package static let bundled: [String: [String: String]] = bundledTables
}
