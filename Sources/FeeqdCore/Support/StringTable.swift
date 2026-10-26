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
    case commentPlaceholder = "comment.placeholder"
    case commentReplyPlaceholder = "comment.replyPlaceholder"
    case commentSend = "comment.send"
    case commentReply = "comment.reply"
    case commentTeam = "comment.team"
    case commentPinned = "comment.pinned"
    case commentPending = "comment.pending"
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
    case submitDone = "submit.done"
    case submitAnonymousNotAllowed = "submit.anonymousNotAllowed"
    case submitQuotaExceeded = "submit.quotaExceeded"
    case submitClosed = "submit.closed"
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
}

/// Every string the SDK shows, and where it comes from.
///
/// Resolution, first match wins: the integrator's override in code → the dashboard's copy for
/// the user's locale (`es-MX`) → for its base language (`es`) → the bundled table for the
/// locale → for the base language → English. The bundled tables are complete in English and
/// Spanish, so the first launch without network still reads right.
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

    /// `es-MX` → `es-MX`, `es_MX`, `es`: remote tables are keyed by whatever the dashboard saved.
    private var candidates: [String] {
        languages.flatMap { tag -> [String] in
            let base = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag
            return [tag, tag.replacingOccurrences(of: "-", with: "_"), base]
        }
    }

    package static let bundled: [String: [String: String]] = [
        "en": [
            "board.title": "Feedback",
            "tab.open": "Open",
            "tab.done": "Done",
            "search.prompt": "Search requests",
            "empty.title": "Nothing here yet",
            "empty.message": "Be the first to ask for something.",
            "search.empty": "No requests match your search.",
            "tab.empty": "Nothing in this list yet.",
            "error.title": "Couldn't load",
            "error.message": "Check your connection and try again.",
            "error.retry": "Try again",
            "error.rateLimited": "Too many requests. Try again in a minute.",
            "common.ok": "OK",
            "common.close": "Close",
            "vote.upvote": "Upvote",
            "vote.voted": "Voted",
            "entry.anonymousAuthor": "Anonymous",
            "comments.title": "Comments",
            "comments.empty": "No comments yet.",
            "entry.only_you_hint": "Only you and the team see this for now.",
            "tab.mine": "Mine",
            "comment.placeholder": "Add a comment",
            "comment.replyPlaceholder": "Write a reply",
            "comment.send": "Send",
            "comment.reply": "Reply",
            "comment.team": "Team",
            "comment.pinned": "Pinned",
            "comment.pending": "Waiting for the team to approve it.",
            "translate.see": "See translation",
            "translate.original": "See original",
            "submit.cta": "New request",
            "submit.title": "New request",
            "submit.titlePlaceholder": "What would you like?",
            "submit.descriptionPlaceholder": "Add details (optional)",
            "submit.send": "Send",
            "submit.cancel": "Cancel",
            "submit.similar": "Already asked",
            "submit.sent.title": "Sent",
            "submit.sent.message": "It will appear in the list once the team reviews it.",
            "submit.done": "Done",
            "submit.anonymousNotAllowed": "This board doesn't accept anonymous requests.",
            "submit.quotaExceeded": "The team can't take new requests right now. Try again later.",
            "submit.closed": "The team isn't taking new requests right now. You can still vote and comment.",
            "poweredBy": "Powered by Feeqd",
            "chat.title": "Message us",
            "chat.button": "Message the team",
            "chat.empty.title": "Talk to the team",
            "chat.empty.message": "Something wrong, or an idea? Write here — only the team sees it, and the answer arrives here.",
            "chat.placeholder": "Message",
            "chat.send": "Send",
            "chat.team": "Team",
            "chat.you": "You",
            "chat.closed": "Marked as done. Write again if you need anything else.",
            "chat.quotaExceeded": "The team can't take new conversations right now. Try again later.",
            "chat.tooLong": "That message is too long.",
            "chat.unread": "New reply",
            "hub.requests": "Feature Requests",
            "hub.bugs": "Bugs",
            "hub.roadmap": "Roadmap",
            "home.title": "How can we help?",
            "home.subtitle": "The team reads everything here.",
            "home.chat": "Message the team",
            "roadmap.empty": "Nothing here yet.",
            "roadmap.feature": "Feature",
            "roadmap.lane.planned": "Planned",
            "roadmap.lane.progress": "In progress",
            "roadmap.lane.done": "Done",
            "roadmap.bugFix": "Bug fix",
            "hub.sections": "Sections",
        ],
        "es": [
            "board.title": "Sugerencias",
            "tab.open": "Abiertas",
            "tab.done": "Hechas",
            "search.prompt": "Buscar sugerencias",
            "empty.title": "Todavía no hay nada",
            "empty.message": "Sé el primero en pedir algo.",
            "search.empty": "Ninguna sugerencia coincide con tu búsqueda.",
            "tab.empty": "Todavía no hay nada en esta lista.",
            "error.title": "No se pudo cargar",
            "error.message": "Revisa tu conexión y vuelve a intentarlo.",
            "error.retry": "Reintentar",
            "error.rateLimited": "Demasiadas peticiones. Vuelve a intentarlo en un minuto.",
            "common.ok": "OK",
            "common.close": "Cerrar",
            "vote.upvote": "Votar",
            "vote.voted": "Votada",
            "entry.anonymousAuthor": "Anónimo",
            "comments.title": "Comentarios",
            "comments.empty": "Todavía no hay comentarios.",
            "entry.only_you_hint": "Por ahora solo lo veis tú y el equipo.",
            "tab.mine": "Mías",
            "comment.placeholder": "Añade un comentario",
            "comment.replyPlaceholder": "Escribe una respuesta",
            "comment.send": "Enviar",
            "comment.reply": "Responder",
            "comment.team": "Equipo",
            "comment.pinned": "Fijado",
            "comment.pending": "Pendiente de que el equipo lo apruebe.",
            "translate.see": "Ver traducción",
            "translate.original": "Ver original",
            "submit.cta": "Nueva sugerencia",
            "submit.title": "Nueva sugerencia",
            "submit.titlePlaceholder": "¿Qué te gustaría?",
            "submit.descriptionPlaceholder": "Añade detalles (opcional)",
            "submit.send": "Enviar",
            "submit.cancel": "Cancelar",
            "submit.similar": "Ya lo han pedido",
            "submit.sent.title": "Enviada",
            "submit.sent.message": "Aparecerá en la lista cuando el equipo la revise.",
            "submit.done": "Hecho",
            "submit.anonymousNotAllowed": "Este tablero no acepta sugerencias anónimas.",
            "submit.quotaExceeded": "El equipo no puede recibir sugerencias nuevas ahora mismo. Inténtalo más tarde.",
            "submit.closed": "El equipo no está recibiendo sugerencias nuevas ahora mismo. Puedes seguir votando y comentando.",
            "poweredBy": "Con la tecnología de Feeqd",
            "chat.title": "Escríbenos",
            "chat.button": "Escribir al equipo",
            "chat.empty.title": "Habla con el equipo",
            "chat.empty.message": "¿Algo va mal o tienes una idea? Escribe aquí: solo lo ve el equipo, y la respuesta llega aquí.",
            "chat.placeholder": "Mensaje",
            "chat.send": "Enviar",
            "chat.team": "Equipo",
            "chat.you": "Tú",
            "chat.closed": "Marcada como resuelta. Escribe de nuevo si necesitas algo más.",
            "chat.quotaExceeded": "El equipo no puede abrir conversaciones nuevas ahora mismo. Inténtalo más tarde.",
            "chat.tooLong": "El mensaje es demasiado largo.",
            "chat.unread": "Respuesta nueva",
            "hub.requests": "Peticiones",
            "hub.bugs": "Errores",
            "hub.roadmap": "Roadmap",
            "home.title": "¿En qué podemos ayudarte?",
            "home.subtitle": "El equipo lee todo lo que llega aquí.",
            "home.chat": "Escribir al equipo",
            "roadmap.empty": "Todavía no hay nada.",
            "roadmap.feature": "Novedad",
            "roadmap.lane.planned": "Previsto",
            "roadmap.lane.progress": "En curso",
            "roadmap.lane.done": "Hecho",
            "roadmap.bugFix": "Arreglo",
            "hub.sections": "Secciones",
        ],
    ]
}
