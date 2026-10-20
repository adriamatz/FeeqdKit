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

    let client: FeeqdClient
    let roadmap: RoadmapStore
    private let preferredBoardID: String?
    private let showsChatButton: Bool
    private var stores: [String: BoardStore] = [:]

    init(context: FeeqdContext) {
        client = context.client
        roadmap = RoadmapStore(client: context.client)
        preferredBoardID = context.preferredBoardID
        showsChatButton = context.showsChatButton
    }

    func load() async {
        do {
            let resolved = try await client.config()
            config = resolved
            plan = HubPlan.make(config: resolved, preferredBoardID: preferredBoardID)
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
/// It carries its own `NavigationStack`, so the host presents it however it likes.
package struct HubScreen: View {
    private let context: FeeqdContext
    @StateObject private var model: HubModel
    @State private var selected: String?
    @State private var showingSubmit = false
    @State private var showingChat = false
    /// True when the host presented the screen (a sheet, a cover): then it needs its own way
    /// out, because not everyone knows a sheet closes with a swipe.
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    package init(context: FeeqdContext) {
        self.context = context
        _model = StateObject(wrappedValue: HubModel(context: context))
    }

    private var strings: StringTable { context.strings.with(remote: model.config.strings) }
    private var theme: ResolvedTheme { ResolvedTheme(config: model.config, overrides: context.themeOverrides) }
    private var plan: HubPlan { model.plan }

    private var current: HubSection? {
        plan.sections.first { $0.id == selected } ?? plan.sections.first
    }

    package var body: some View {
        NavigationStack {
            root
                .navigationDestination(for: Entry.self) { entry in
                    EntryDetailScreen(entryID: entry.id, store: model.store(for: entry.boardID), seed: entry)
                }
                .navigationDestination(for: HubSection.self) { section in
                    sectionScreen(section, fromHome: true)
                }
                .navigationDestination(isPresented: $showingChat) {
                    ChatScreen(client: context.client)
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
        .tint(theme.primary)
        .feeqdFontDesign(theme.fontDesign)
        .environment(\.feeqdStrings, strings)
        .environment(\.feeqdTheme, theme)
        .task { await model.load() }
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
                HomeScreen(plan: plan, chat: model.chat, label: label(for:)) { showingChat = true }
                    .navigationTitle(plan.title)
                    .feeqdInlineTitle()
                    .toolbar { closeItem }
            } else if let current {
                sectionScreen(current, fromHome: false)
            }
        }
    }

    // MARK: One section, with the chrome its layout asks for

    private func sectionScreen(_ section: HubSection, fromHome: Bool) -> some View {
        sectionContent(section)
            .navigationTitle(fromHome || plan.style == .single ? label(for: section) : (plan.style == .chips ? plan.title : ""))
            .feeqdInlineTitle()
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
                    if section.boardID != nil && model.config.behaviour.submitEnabled && model.config.acceptingEntries {
                        Button {
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
            BoardListView(store: model.store(for: id), reservesChatRoom: model.chat.available)
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
                            .background(.bar)
                    }
                }
        case .roadmap:
            RoadmapView(store: model.roadmap, showVotes: plan.showVotes) { await model.reloadRoadmap() }
        }
    }

    private func label(for section: HubSection) -> String {
        if !section.label.isEmpty { return section.label }
        switch section.kind {
        case let .board(_, isBugs): return strings(isBugs ? .sectionBugs : .sectionRequests)
        case .roadmap: return strings(.sectionRoadmap)
        }
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
        .background(.bar)
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var closeItem: some ToolbarContent {
        if isPresented {
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
    let reservesChatRoom: Bool
    @State private var tab: SDKConfig.Tab = .open
    @State private var searchText = ""

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        content
            .searchable(text: $searchText, prompt: strings(.searchPrompt))
            .task { if store.needsLoad { await store.load() } }
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
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            list
        }
    }

    private var showsTabs: Bool { store.visibleTabs.count > 1 && store.query.isEmpty }

    private var list: some View {
        let rows = showsTabs ? store.entries(in: tab) : store.entries
        return List {
            if showsTabs {
                // Open / Done as two small chips with their counts, not a second full-width
                // segmented control under the section switcher.
                HStack(spacing: 8) {
                    ForEach(store.visibleTabs, id: \.self) { option in
                        let on = option == tab
                        Button {
                            tab = option
                        } label: {
                            HStack(spacing: 4) {
                                Text(option == .done ? strings(.tabDone) : option == .mine ? strings(.tabMine) : strings(.tabOpen))
                                Text("\(store.entries(in: option).count)")
                                    .foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary)
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(Capsule().fill(on ? theme.primary : Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
            ForEach(rows) { entry in
                NavigationLink(value: entry) {
                    EntryRow(
                        entry: entry,
                        status: store.status(for: entry.state),
                        voted: store.votedIDs.contains(entry.id),
                        behaviour: store.config.behaviour
                    ) {
                        Task { await store.toggleVote(entryID: entry.id) }
                    }
                }
                .task { await store.loadMoreIfNeeded(current: entry) }
            }
            if rows.isEmpty {
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
            if store.config.behaviour.poweredByFeeqd {
                PoweredByFeeqd().listRowSeparator(.hidden)
            }
            if reservesChatRoom {
                // Room under the last row, so the floating chat button never covers it.
                Color.clear.frame(height: 64).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.load() }
    }
}

// MARK: - Front page

/// The "Support first" front door: the chat on top, a card per section below.
struct HomeScreen: View {
    let plan: HubPlan
    let chat: ChatStatus
    let label: (HubSection) -> String
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
                        NavigationLink(value: section) {
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
    let reload: () async -> Void
    @State private var selected = 0

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
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

    /// A team roadmap's lanes are named here, in the user's language; the admin's columns keep theirs.
    private func laneLabel(_ column: HubLayout.Column) -> String {
        switch column.id {
        case "lane.open": return strings(.roadmapLanePlanned)
        case "lane.progress": return strings(.roadmapLaneProgress)
        case "lane.closed": return strings(.roadmapLaneDone)
        default: return column.label
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
                    NavigationLink(value: item.entry) {
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
                VStack(spacing: 1) {
                    Image(systemName: "arrowtriangle.up.fill").font(.caption2)
                    Text("\(item.entry.voteCount)").font(.caption.weight(.semibold)).monospacedDigit()
                }
                .frame(width: 40, height: 44)
                .foregroundStyle(theme.textSecondary)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.1)))
                .accessibilityLabel("\(item.entry.voteCount) \(strings(.voteUpvote))")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous).fill(theme.surface))
    }
}
