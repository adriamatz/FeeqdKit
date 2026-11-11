import FeeqdCore
import SwiftUI

/// Loads `/sdk/config` once, turns it into a `HubPlan`, and keeps one `BoardStore` per board
/// section so switching sections never reloads a list already on screen.
@MainActor
final class HubModel: ObservableObject {
    enum Phase: Equatable {
        case loading, loaded
        case failed(FeeqdError)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var config: SDKConfig = .fallback
    @Published private(set) var plan = HubPlan.make(config: .fallback, preferredBoardID: nil)
    @Published var chat = ChatStatus.unavailable
    /// The app's say (`Feeqd.setCanSubmit`, and whether the user pays), kept here so the "+"
    /// redraws when it changes.
    @Published private(set) var gate: SubmitGate.State

    let client: FeeqdClient
    let roadmap: RoadmapStore
    private let preferredBoardID: String?
    private let showsChatButton: Bool
    private let submitGate: SubmitGate
    private var stores: [String: BoardStore] = [:]

    init(context: FeeqdContext) {
        client = context.client
        roadmap = RoadmapStore(client: context.client)
        preferredBoardID = context.preferredBoardID
        showsChatButton = context.showsChatButton
        submitGate = context.submitGate
        gate = context.submitGate.current
        // The config read at launch: the tabs are there from the first frame, not after a request.
        if let cached = client.lastConfig {
            let cachedPlan = HubPlan.make(config: cached, preferredBoardID: preferredBoardID)
            if !cachedPlan.sections.isEmpty {
                config = cached
                plan = cachedPlan
                phase = .loaded
            }
        }
    }

    func load() async {
        do {
            let resolved = try await client.config()
            config = resolved
            let fresh = HubPlan.make(config: resolved, preferredBoardID: preferredBoardID)
            if fresh != plan { plan = fresh }
            guard !plan.sections.isEmpty else { throw FeeqdError.noBoard }
            phase = .loaded
            if plan.sections.contains(where: { $0.kind == .roadmap }) {
                Task { await roadmap.load(boards: resolved.boards, columns: plan.columns, order: plan.order, roadmapID: plan.roadmapID) }
            }
            await refreshChat()
        } catch {
            if FeeqdError.isCancellation(error) { return }
            phase = .failed(FeeqdError.wrap(error))
        }
    }

    func reloadRoadmap() async {
        await roadmap.load(boards: config.boards, columns: plan.columns, order: plan.order, roadmapID: plan.roadmapID)
    }

    /// Reads the config again (usually a `304`): what the plan still accepts may have changed,
    /// or a `429 quota_exceeded` just said so.
    func refreshConfig() async {
        guard let resolved = try? await client.config() else { return }
        config = resolved
    }

    var submitAccess: SubmitAccess { .resolve(config: config, canSubmit: gate.canSubmit, pays: gate.pays) }

    func refreshCanSubmit() {
        gate = submitGate.current
    }

    func refreshChat() async {
        guard showsChatButton, plan.chatEnabled else {
            chat = .unavailable
            return
        }
        chat = await ChatStatus.check(client, acceptingNew: config.acceptingConversations)
    }

    func store(for boardID: String) -> BoardStore {
        if let existing = stores[boardID] { return existing }
        let created = BoardStore(client: client, preferredBoardID: boardID, initialConfig: config.scoped(to: boardID))
        stores[boardID] = created
        return created
    }
}

/// The in-app hub: requests, bugs, roadmap and chat, laid out the way the admin chose in the
/// dashboard. With nothing chosen it is what FeeqdKit always was — one board, chat on top.
///
/// It carries its own `NavigationStack`, so the host presents it however it likes; or, with
/// `ownsNavigation` false, it is one more screen of the host's stack, pushed onto it.
package struct HubScreen: View {
    private let context: FeeqdContext
    private let ownsNavigation: Bool
    @StateObject private var model: HubModel
    @State private var selected: String?
    @State private var showingSubmit = false
    /// The app keeps new requests for some users (`Feeqd.setCanSubmit`) and this is not one.
    @State private var showingSubmitBlocked = false
    @State private var showingChat = false
    /// The front page's section open. A state and a destination, not value links: those, pushed
    /// onto the host's stack, went back to the list instead of opening.
    @State private var openedSection: HubSection?
    /// What is typed in each board's search, kept here because the search bar is the hub's.
    @State private var searchTexts: [String: String] = [:]
    /// True when the host presented the screen (a sheet, a cover): then it needs its own way
    /// out, because not everyone knows a sheet closes with a swipe.
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    package init(context: FeeqdContext, ownsNavigation: Bool = true) {
        self.context = context
        self.ownsNavigation = ownsNavigation
        _model = StateObject(wrappedValue: HubModel(context: context))
    }

    private var strings: StringTable { context.strings.with(remote: model.config.strings) }
    private var theme: ResolvedTheme { ResolvedTheme(config: model.config, overrides: context.themeOverrides) }
    private var plan: HubPlan { model.plan }

    private var current: HubSection? {
        plan.sections.first { $0.id == selected } ?? plan.sections.first
    }

    package var body: some View {
        Group {
            if ownsNavigation {
                NavigationStack { navigable }
            } else {
                navigable
            }
        }
        .tint(theme.primary)
        .feeqdFontDesign(theme.fontDesign)
        .environment(\.feeqdStrings, strings)
        .environment(\.feeqdTheme, theme)
        .environment(\.feeqdTranslation, context.translation)
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: SubmitGate.didChange)) { _ in model.refreshCanSubmit() }
        .alert(strings(.submitBlocked), isPresented: $showingSubmitBlocked) {
            Button(strings(.ok), role: .cancel) {}
        }
        .sheet(isPresented: $showingSubmit, onDismiss: { Task { await model.refreshConfig() } }) {
            if let boardID = current?.boardID {
                SubmitSheet(store: model.store(for: boardID))
                    .environment(\.feeqdStrings, strings)
                    .environment(\.feeqdTheme, theme)
                    .tint(theme.primary)
                    .feeqdFontDesign(theme.fontDesign)
            }
        }
    }

    /// The root and where it leads. Each destination gets the theme and texts itself: pushed onto
    /// the host's stack, it may take its environment from the stack rather than from here.
    private var navigable: some View {
        root
            .navigationDestination(
                isPresented: Binding(get: { openedSection != nil }, set: { if !$0 { openedSection = nil } })
            ) {
                if let openedSection {
                    styled(sectionScreen(openedSection, fromHome: true))
                }
            }
            .navigationDestination(isPresented: $showingChat) {
                styled(ChatScreen(client: context.client))
            }
            .onChange(of: showingChat) { showing in
                // Back from the chat: whatever was unread has just been read.
                if !showing {
                    Task {
                        await model.refreshConfig()
                        await model.refreshChat()
                    }
                }
            }
    }

    private func styled(_ screen: some View) -> some View {
        screen
            .tint(theme.primary)
            .feeqdFontDesign(theme.fontDesign)
            .environment(\.feeqdStrings, strings)
            .environment(\.feeqdTheme, theme)
            .environment(\.feeqdTranslation, context.translation)
    }

    @ViewBuilder
    private var root: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { closeItem }
        case let .failed(error):
            ErrorStateView(error: error) { Task { await model.load() } }
                .toolbar { closeItem }
        case .loaded:
            if plan.style == .home {
                HomeScreen(
                    plan: plan, chat: model.chat, label: label(for:), openSection: { openedSection = $0 },
                    showsNote: !model.config.behaviour.listNoteHidden
                ) {
                    showingChat = true
                }
                    .navigationTitle(title)
                    .feeqdInlineTitle(theme)
                    .toolbar { closeItem }
            } else if let current {
                sectionScreen(current, fromHome: false)
            }
        }
    }

    // MARK: One section, with the chrome its layout asks for

    private func sectionScreen(_ section: HubSection, fromHome: Bool) -> some View {
        sectionContent(section)
            .navigationTitle(fromHome || plan.style == .single ? label(for: section) : (plan.style == .chips ? title : ""))
            .feeqdInlineTitle(theme)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !fromHome && plan.style == .chips { chips }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.chat.available && plan.style != .home { chatButton }
            }
            .toolbar {
                if !fromHome { closeItem }
                if !fromHome && plan.style == .bar {
                    ToolbarItem(placement: .principal) { segmented }
                }
                if !fromHome && plan.style == .menu {
                    ToolbarItem(placement: .principal) { titleMenu }
                }
                ToolbarItem(placement: .primaryAction) {
                    if section.boardID != nil && model.submitAccess != .hidden {
                        Button {
                            if model.submitAccess == .blocked {
                                showingSubmitBlocked = true
                                return
                            }
                            selected = section.id
                            showingSubmit = true
                        } label: {
                            Label(strings(.submitCTA), systemImage: "plus")
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private func sectionContent(_ section: HubSection) -> some View {
        switch section.kind {
        case let .board(id, _):
            let searchText = Binding(get: { searchTexts[id, default: ""] }, set: { searchTexts[id] = $0 })
            BoardListView(store: model.store(for: id), searchText: searchText, reservesChatRoom: model.chat.available)
                .id(id)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.config.behaviour.submitEnabled && !model.config.acceptingEntries {
                        Text(strings(.submitClosed))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(theme.background)
                    }
                }
                // Outside the `.id`: inside it, every board switch installed a new search bar,
                // and the navigation bar redrew the section switcher from nothing, its labels
                // piled on top of each other for a moment.
                // A section switcher in the bar leaves no room for a search button beside it.
                .feeqdSearchable(text: searchText, prompt: strings(.searchPrompt), asButton: plan.style != .bar)
        case .roadmap:
            RoadmapView(store: model.roadmap, showVotes: plan.showVotes, boardStore: model.store(for:)) {
                await model.reloadRoadmap()
            }
        }
    }

    /// What older dashboards saved as a name before a name could be left empty: the English
    /// defaults, which read as "use the app's own" rather than as the team's choice.
    private static let stockLabels: Set<String> = ["Requests", "Bugs", "Roadmap", "Chat"]

    /// A tab's name: the team's for the user's language, then the one name an older dashboard
    /// saved for every language, then the app's own.
    private func label(for section: HubSection) -> String {
        let key: String
        switch section.kind {
        case let .board(id, _): key = "hub.board.b\(id)"
        case .roadmap: key = StringKey.sectionRoadmap.rawValue
        }
        if let name = strings.custom(key) { return name }
        if !section.label.isEmpty, !Self.stockLabels.contains(section.label) { return section.label }
        switch section.kind {
        case let .board(_, isBugs): return strings(isBugs ? .sectionBugs : .sectionRequests)
        case .roadmap: return strings(.sectionRoadmap)
        }
    }

    /// The hub's title, found the same way as a tab's name.
    private var title: String {
        if let name = strings.custom(StringKey.boardTitle.rawValue) { return name }
        if !plan.title.isEmpty, plan.title != "Feedback" { return plan.title }
        return strings(.boardTitle)
    }

    // MARK: Switchers

    private var selection: Binding<String> {
        Binding(get: { current?.id ?? "" }, set: { selected = $0 })
    }

    private var segmented: some View {
        Picker(strings(.sections), selection: selection) {
            ForEach(plan.sections) { Text(label(for: $0)).tag($0.id) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: CGFloat(plan.sections.count) * 92)
    }

    private var titleMenu: some View {
        Menu {
            Picker(strings(.sections), selection: selection) {
                ForEach(plan.sections) { Text(label(for: $0)).tag($0.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.map(label(for:)) ?? "").font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(strings(.sections))
    }

    /// Any number of sections, all visible, one line tall.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(plan.sections) { section in
                    let on = section.id == current?.id
                    Button {
                        selected = section.id
                    } label: {
                        Text(label(for: section))
                            .font(.subheadline.weight(on ? .semibold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(Capsule().fill(on ? theme.primary : Color.secondary.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(theme.background)
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var closeItem: some ToolbarContent {
        // Pushed onto the host's stack, the way out is its back button.
        if ownsNavigation && isPresented {
            ToolbarItem(placement: .feeqdLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(strings(.close))
            }
        }
    }

    /// Floating, bottom right: where a thumb rests, and where people already look for a chat.
    private var chatButton: some View {
        Button {
            showingChat = true
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(theme.primary))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .overlay(alignment: .topTrailing) {
                    if model.chat.hasUnread {
                        Circle()
                            .fill(.red)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(strings(.chatButton))
        .accessibilityValue(model.chat.hasUnread ? strings(.chatUnread) : "")
    }
}

// MARK: - A board's list

/// One board: open/done, search, the list, votes. What `BoardScreen` used to be, minus the
/// navigation the hub now owns.
struct BoardListView: View {
    @ObservedObject var store: BoardStore
    /// The search bar itself is the hub's (`HubScreen.sectionContent`); the list runs the search.
    @Binding var searchText: String
    let reservesChatRoom: Bool
    @State private var tab: SDKConfig.Tab = .open
    /// The request open in the detail. A button and this, not a `NavigationLink` row: pushed onto
    /// the host's stack, a link row stays highlighted after coming back.
    @State private var opened: Entry?

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme
    @Environment(\.feeqdTranslation) private var translation

    var body: some View {
        content
            // Behind the list and the empty, loading and error states alike, which otherwise
            // show the system's background.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .task { if store.needsLoad { await store.load() } }
            // On leaving too: what arrived while it was open was seen as well.
            .onAppear { store.markSeen() }
            .onDisappear { store.markSeen() }
            .task(id: searchText) {
                guard !searchText.isEmpty || !store.query.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.search(searchText)
            }
            .onChange(of: store.visibleTabs) { tabs in
                if !tabs.contains(tab), let first = tabs.first { tab = first }
            }
            .alert(
                strings(.errorTitle),
                isPresented: Binding(get: { store.lastActionError != nil }, set: { if !$0 { store.lastActionError = nil } }),
                presenting: store.lastActionError
            ) { _ in
                Button(strings(.ok), role: .cancel) {}
            } message: { error in
                Text(feeqdMessage(for: error, strings: strings))
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            switch store.phase {
            case let .failed(error):
                ErrorStateView(error: error) { Task { await store.load() } }
            case .loaded:
                EmptyStateView(isSearch: !store.query.isEmpty)
                    .refreshable { await store.load() }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if store.query.isEmpty, !store.config.behaviour.listNoteHidden, let note = strings.listNote {
                            TeamNote(text: note)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }
                    }
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            list
        }
    }

    private var showsTabs: Bool { store.visibleTabs.count > 1 && store.query.isEmpty }
    /// Search orders by relevance, so the order menu goes while there is a query.
    private var showsOrder: Bool { store.canChangeOrder && store.query.isEmpty }

    /// Open / Done, and the order menu beside it when the dashboard lets people pick. Not in the
    /// navigation bar: a second item there next to the search reopens it on iOS 27.
    private var tabPicker: some View {
        HStack(spacing: 8) {
            if showsTabs {
                Picker("", selection: $tab) {
                    ForEach(store.visibleTabs, id: \.self) { option in
                        let total = store.count(in: option)
                        Group {
                            if let count = total.count {
                                Text("\(tabLabel(option)) (\(count)\(total.isComplete ? "" : "+"))")
                            } else {
                                Text(tabLabel(option))
                            }
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Spacer()
            }
            if showsOrder { orderMenu }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    private var orderMenu: some View {
        Menu {
            Picker(strings(.sortTitle), selection: Binding(get: { store.order }, set: { next in Task { await store.setOrder(next) } })) {
                ForEach(ListOrder.allCases, id: \.self) { option in
                    Text(orderLabel(option)).tag(option)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                Text(orderLabel(store.order))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.textSecondary.opacity(0.25)))
            .contentShape(Capsule())
        }
        .accessibilityLabel("\(strings(.sortTitle)): \(orderLabel(store.order))")
    }

    private func orderLabel(_ order: ListOrder) -> String {
        switch order {
        case .votes: return strings(.sortVotes)
        case .recent: return strings(.sortRecent)
        case .status: return strings(.sortStatus)
        }
    }

    private enum RowLook { case compact, cards, spotlight }

    /// One request in the look the dashboard picked. A spotlight `rank` is a row under the
    /// headline card; no rank is the headline itself.
    @ViewBuilder
    private func row(
        _ entry: Entry, style: RowLook, rank: Int? = nil, showsStatus: Bool = true, scope: SDKConfig.Tab?
    ) -> some View {
        let status = store.status(for: entry.state)
        let voted = store.votedIDs.contains(entry.id)
        let behaviour = store.config.behaviour
        let vote = { Task { await store.toggleVote(entryID: entry.id) } }
        let cell = Button {
            opened = entry
        } label: {
            Group {
                switch style {
                case .compact:
                    EntryRow(entry: entry, status: status, voted: voted, behaviour: behaviour, showsStatus: showsStatus) { _ = vote() }
                case .cards:
                    EntryCard(entry: entry, status: status, voted: voted, behaviour: behaviour, showsStatus: showsStatus) { _ = vote() }
                case .spotlight:
                    if let rank {
                        RankedRow(rank: rank, entry: entry, status: status, voted: voted, behaviour: behaviour) { _ = vote() }
                    } else {
                        SpotlightCard(entry: entry, status: status, voted: voted, behaviour: behaviour) { _ = vote() }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await store.loadMoreIfNeeded(current: entry, in: scope) }
        if style == .cards || (style == .spotlight && rank == nil) {
            // Cards and the headline sit apart, with no hairlines between them.
            cell
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        } else {
            // The separator starts at the row's left edge.
            cell.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        }
    }

    private func tabLabel(_ tab: SDKConfig.Tab) -> String {
        switch tab {
        case .open: return strings(.tabOpen)
        case .done: return strings(.tabDone)
        case .mine: return strings(.tabMine)
        }
    }

    private var list: some View {
        let scope = showsTabs ? tab : nil
        let rows = store.entries(in: scope)
        let style = store.config.behaviour.rowStyle
        let browsing = store.query.isEmpty
        return List {
            if browsing, !store.config.behaviour.listNoteHidden, let note = strings.listNote {
                // A row, not pinned with the tabs: it scrolls away once read.
                Section {
                    TeamNote(text: note)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
                .listSectionSeparator(.hidden)
                .listRowBackground(theme.background)
            }
            if store.order == .status && browsing && !rows.isEmpty {
                // By status: each status's name over its requests, the furthest along first. The
                // names are rows, not section headers, which would put a table's gap around each.
                Section {
                    ForEach(store.statusGroups(in: scope)) { group in
                        StatusGroupHeader(status: group.status, slug: group.slug, count: group.entries.count)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 2, trailing: 16))
                        ForEach(group.entries) { entry in
                            row(entry, style: style == .cards ? .cards : .compact, showsStatus: false, scope: scope)
                        }
                    }
                }
                .listSectionSeparator(.hidden)
                .listRowBackground(theme.background)
            } else if style == .spotlight && store.order == .votes && browsing, let first = rows.first {
                // The most voted large on top, the rest ranked under it.
                Section {
                    row(first, style: .spotlight, scope: scope)
                    ForEach(Array(rows.dropFirst().enumerated()), id: \.element.id) { index, entry in
                        row(entry, style: .spotlight, rank: index + 2, scope: scope)
                    }
                }
                .listSectionSeparator(.hidden)
                .listRowBackground(theme.background)
            } else {
                Section {
                    ForEach(rows) { entry in row(entry, style: style == .cards ? .cards : .compact, scope: scope) }
                }
                // Lines between rows only: none over the first or under the footer.
                .listSectionSeparator(.hidden)
                .listRowBackground(theme.background)
            }
            Section {
                if rows.isEmpty, store.hasMore, showsTabs, tab != .mine {
                    // Nothing of this tab in what is loaded yet, but the board goes on: fetch on.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                        .task(id: store.entries.count) { await store.loadMore() }
                } else if rows.isEmpty {
                    Text(store.query.isEmpty ? strings(.tabEmpty) : strings(.searchEmpty))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
                if store.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                }
            } footer: {
                VStack(spacing: 0) {
                    if store.config.behaviour.poweredByFeeqd {
                        PoweredByFeeqd()
                    }
                    if reservesChatRoom {
                        // Room under the last row, so the floating chat button never covers it.
                        Color.clear.frame(height: 64)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listSectionSeparator(.hidden)
            .listRowBackground(theme.background)
        }
        .feeqdRowList(theme)
        .feeqdTightSections()
        .safeAreaInset(edge: .top, spacing: 0) {
            // Open / Closed across the width, pinned under the title: what a list of requests
            // in an iOS app usually opens with.
            if showsTabs || showsOrder { tabPicker }
        }
        .refreshable { await store.load() }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened {
                EntryDetailScreen(entryID: opened.id, store: store, seed: opened)
                    .environment(\.feeqdStrings, strings)
                    .environment(\.feeqdTheme, theme)
                    .environment(\.feeqdTranslation, translation)
                    .tint(theme.primary)
            }
        }
    }
}

// MARK: - Front page

/// The "Support first" front door: the chat on top, a card per section below.
struct HomeScreen: View {
    let plan: HubPlan
    let chat: ChatStatus
    let label: (HubSection) -> String
    let openSection: (HubSection) -> Void
    /// The dashboard can keep the team's message without showing it.
    var showsNote = true
    let openChat: () -> Void

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings(.homeTitle)).font(.title2.bold())
                    Text(strings(.homeSubtitle)).font(.subheadline).foregroundStyle(.secondary)
                }
                if showsNote, let note = strings.listNote {
                    TeamNote(text: note)
                }
                if chat.available {
                    Button(action: openChat) {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(strings(.homeChat)).font(.headline)
                                if chat.hasUnread {
                                    Text(strings(.chatUnread)).font(.subheadline).opacity(0.85)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.primary))
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(plan.sections) { section in
                        Button {
                            openSection(section)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: icon(for: section))
                                    .font(.headline)
                                    .foregroundStyle(tint(for: section))
                                    .frame(width: 36, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint(for: section).opacity(0.15)))
                                Text(label(section)).font(.headline).foregroundStyle(theme.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.surface))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(theme.background.ignoresSafeArea())
    }

    private func icon(for section: HubSection) -> String {
        switch section.kind {
        case let .board(_, isBugs): return isBugs ? "ladybug.fill" : "lightbulb.fill"
        case .roadmap: return "map.fill"
        }
    }

    private func tint(for section: HubSection) -> Color {
        switch section.kind {
        case let .board(_, isBugs): return isBugs ? .red : .orange
        case .roadmap: return .green
        }
    }
}

// MARK: - Roadmap

/// The roadmap as stages you step through: a pill per column on top, the column's cards below.
/// Cards, not rows — a roadmap is read for "what's coming", not triaged.
struct RoadmapView: View {
    @ObservedObject var store: RoadmapStore
    let showVotes: Bool
    /// The board's store, for the request a card opens.
    let boardStore: (String) -> BoardStore
    let reload: () async -> Void
    @State private var selected = 0
    /// The card open in the detail. A button and this, like the board's rows: a value link pushed
    /// onto the host's stack went back to the list instead of opening the request.
    @State private var opened: Entry?

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme
    @Environment(\.feeqdTranslation) private var translation

    var body: some View {
        phases
            // Behind the columns and the loading and error states, which otherwise show the
            // system's background.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var phases: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(error):
            ErrorStateView(error: error) { Task { await reload() } }
        case .loaded:
            VStack(spacing: 0) {
                pills
                pages
            }
            .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
                if let opened {
                    EntryDetailScreen(entryID: opened.id, store: boardStore(opened.boardID), seed: opened)
                        .environment(\.feeqdStrings, strings)
                        .environment(\.feeqdTheme, theme)
                        .environment(\.feeqdTranslation, translation)
                        .tint(theme.primary)
                }
            }
        }
    }

    /// A native segmented control, as iOS apps show stages: one column at a time, full width.
    private var pills: some View {
        Picker(strings(.sectionRoadmap), selection: $selected) {
            ForEach(Array(store.columns.enumerated()), id: \.offset) { index, column in
                let label = laneLabel(column.column)
                Text(column.items.isEmpty ? label : "\(label) \(column.items.count)")
                    .tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The dashboard's columns and their names in English before a name could be left empty.
    private static let stockColumns: [String: (key: StringKey, label: String)] = [
        "next": (.roadmapLanePlanned, "Planned"),
        "now": (.roadmapLaneProgress, "In progress"),
        "shipped": (.roadmapLaneDone, "Shipped"),
    ]

    /// A column's name in the user's language: a team roadmap's lanes are always the app's; the
    /// dashboard's columns are the team's for that language, then their one name, then the app's.
    private func laneLabel(_ column: HubLayout.Column) -> String {
        switch column.id {
        case "lane.open": return strings(.roadmapLanePlanned)
        case "lane.progress": return strings(.roadmapLaneProgress)
        case "lane.closed": return strings(.roadmapLaneDone)
        default:
            if let name = strings.custom("roadmap.column.\(column.id)") { return name }
            if let stock = Self.stockColumns[column.id], column.label.isEmpty || column.label == stock.label {
                return strings(stock.key)
            }
            return column.label
        }
    }

    @ViewBuilder
    private var pages: some View {
        if store.columns.indices.contains(selected) {
            columnView(store.columns[selected].items)
                .id(selected)
                .transition(.opacity)
        }
    }

    private func columnView(_ items: [RoadmapStore.Item]) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                if items.isEmpty {
                    Text(strings(.roadmapEmpty))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                ForEach(items) { item in
                    Button {
                        opened = item.entry
                    } label: {
                        card(item)
                    }
                    .buttonStyle(.plain)
                }
                Color.clear.frame(height: 72)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func card(_ item: RoadmapStore.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label(strings(item.isBug ? .roadmapBugFix : .roadmapFeature), systemImage: item.isBug ? "ladybug.fill" : "lightbulb.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.isBug ? Color.red : Color.orange)
                Text(item.entry.title)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if showVotes {
                RoadmapVote(entry: item.entry, store: boardStore(item.entry.boardID))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.surface))
    }
}

/// A roadmap card's vote: the same control as the list's, on the card's board. It looks like a
/// button, so it is one.
private struct RoadmapVote: View {
    let entry: Entry
    @ObservedObject var store: BoardStore

    var body: some View {
        let current = store.entry(id: entry.id) ?? entry
        VoteButton(
            count: current.voteCount,
            voted: store.votedIDs.contains(entry.id),
            showsCount: true,
            size: 44
        ) {
            Task { await store.toggleVote(entryID: entry.id) }
        }
        .task {
            store.open(entry)
            // Which cards this device already backed comes with the board's first load.
            if store.needsLoad { await store.load() }
        }
    }
}
