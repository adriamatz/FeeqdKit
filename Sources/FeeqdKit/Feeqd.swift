import FeeqdCore
import FeeqdUI
import Foundation
import os
import SwiftUI

/// FeeqdKit's front door: configure once, show a view.
///
/// ```swift
/// import FeeqdKit
///
/// @main struct MyApp: App {
///     init() { Feeqd.configure(with: "feeqd_pk_…") }
///     var body: some Scene { WindowGroup { ContentView() } }
/// }
///
/// // anywhere
/// .sheet(isPresented: $showFeedback) { Feeqd.FeedbackView() }
/// ```
///
/// This enum is the only static entry point, and it holds one immutable configuration behind
/// a lock. There are no public `static var`s to mutate from any thread.
public enum Feeqd {
    /// Production serves reads (go-reader: config, boards, comments) and writes (go-gatherer:
    /// votes, comments, submissions) on separate hosts.
    public static let defaultReaderURL = URL(string: "https://pr1.feeqd.com")!
    public static let defaultGathererURL = URL(string: "https://pw1.feeqd.com")!
    public static let version = FeeqdCoreVersion.current

    private static let state = OSAllocatedUnfairLock<FeeqdContext?>(initialState: nil)

    static var context: FeeqdContext? { state.withLock { $0 } }

    /// Posted on the main actor once `reset()` has taken effect.
    static let didReset = Notification.Name("com.feeqd.feeqdkit.didReset")

    /// `setIdentityToken`, `updateUser` and `reset` take effect in the order they were called:
    /// a sign-out followed at once by the next sign-in must not land the other way round.
    private static let identityQueue = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private static func inOrder(_ work: @escaping @Sendable () async -> Void) {
        identityQueue.withLock { last in
            let previous = last
            last = Task {
                await previous?.value
                await work()
            }
        }
    }

    /// Once, at launch. The key is the publishable one from the dashboard: it ships in the
    /// binary and is public by design.
    public static func configure(with apiKey: String) {
        configure(FeeqdConfiguration(apiKey: apiKey))
    }

    public static func configure(_ configuration: FeeqdConfiguration) {
        let client = FeeqdClient(
            configuration: ClientConfiguration(
                apiKey: configuration.apiKey,
                readerURL: configuration.readerURL,
                gathererURL: configuration.gathererURL,
                appVersion: configuration.appVersion
            ),
            identity: DeviceIdentity()
        )
        let context = FeeqdContext(
            client: client,
            preferredBoardID: configuration.boardID,
            strings: StringTable(overrides: configuration.strings),
            themeOverrides: ThemeOverrides(configuration.theme),
            showsChatButton: configuration.showsChatButton,
            translation: configuration.translation.mode
        )
        state.withLock { $0 = context }
        Task { await client.announceLaunch(preferredBoardID: configuration.boardID) }
        if configuration.collectPurchases { PurchaseWatcher.start(client: client) }
    }

    /// A signed-in user, vouched for by your server: a JWT signed with the key's signing
    /// secret. The secret belongs on your server and never in the app.
    public static func setIdentityToken(_ token: String?) {
        guard let client = context?.client else { return }
        inOrder { await client.setIdentityToken(token) }
    }

    /// Your own user id, name and email, unsigned. Anyone holding the key could send any value,
    /// so the dashboard shows them as unverified. Use `setIdentityToken` when it matters.
    ///
    /// `payment` is what this user pays you, for apps that bill outside the App Store. Leave it
    /// out otherwise: with `collectPurchases` on, FeeqdKit reads App Store purchases on its own.
    public static func updateUser(id: String?, name: String? = nil, email: String? = nil, payment: FeeqdPayment? = nil) {
        guard let client = context?.client else { return }
        let summary = payment?.summary
        inOrder {
            await client.setClaimedIdentity(id: id, name: name, email: email)
            if let summary { await client.setManualPayment(summary) }
        }
    }

    /// Call it when your user signs out. It forgets their identity token, their id, name, email
    /// and payment (App Store purchases included, until the app next comes to the foreground and
    /// reads them again: they belong to the Apple ID, not to your user), and takes a new device id, so the next person to sign in on this install
    /// does not see the previous one's chat or requests. A Feeqd screen still on display (in a
    /// tab, say) starts over, so nothing loaded for the previous user stays on it.
    public static func reset() {
        guard let client = context?.client else { return }
        inOrder {
            await client.reset()
            await MainActor.run { NotificationCenter.default.post(name: didReset, object: nil) }
        }
    }

    /// Whether the chat is available to this user, and whether the team replied since they last
    /// looked. Use it to badge your own entry point:
    ///
    /// ```swift
    /// let chat = await Feeqd.chatStatus()
    /// if chat.isAvailable { /* show a "Message us" row, dotted when chat.hasUnread */ }
    /// ```
    ///
    /// Fails closed: without network, before `configure`, or with a key that lacks chat, the
    /// answer is "not available". Once the team's plan has no room for new conversations, it is
    /// available only to a user who already has one open. Two requests per call; the config one
    /// is usually a `304`.
    public static func chatStatus() async -> FeeqdChatStatus {
        guard let client = context?.client else { return FeeqdChatStatus(isAvailable: false, hasUnread: false) }
        let acceptingNew = (try? await client.config())?.acceptingConversations ?? true
        let status = await ChatStatus.check(client, acceptingNew: acceptingNew)
        return FeeqdChatStatus(isAvailable: status.available, hasUnread: status.hasUnread)
    }

    /// The private chat with your team on its own, for when you want it somewhere other than
    /// the board. Check `chatStatus()` before offering it. Presented, it brings its own
    /// navigation; pushed onto yours, pass `pushed: true`.
    public struct ChatView: View {
        private let pushed: Bool

        /// - Parameter pushed: `true` when you push it onto your own `NavigationStack` (a
        ///   `NavigationLink` in your settings) instead of presenting it.
        public init(pushed: Bool = false) {
            self.pushed = pushed
        }

        public var body: some View {
            if let context = Feeqd.context {
                FreshAfterReset { StandaloneChatScreen(context: context, ownsNavigation: !pushed) }
            } else {
                NotConfiguredView()
            }
        }
    }

    /// The feedback screen: requests, votes, comments and new requests — and, when your key
    /// carries it, a button to message the team. Present it (a sheet, a cover) and it brings
    /// its own navigation and a close button; push it onto yours with `pushed: true` and it is
    /// one more screen of your app, with your back button.
    public struct FeedbackView: View {
        private let pushed: Bool

        /// - Parameter pushed: `true` when you push it onto your own `NavigationStack` (a
        ///   `NavigationLink` in your settings) instead of presenting it.
        public init(pushed: Bool = false) {
            self.pushed = pushed
        }

        public var body: some View {
            if let context = Feeqd.context {
                FreshAfterReset { HubScreen(context: context, ownsNavigation: !pushed) }
            } else {
                NotConfiguredView()
            }
        }
    }
}

/// Rebuilds the screen it wraps when the user signs out: its stores are made again, empty.
private struct FreshAfterReset<Content: View>: View {
    @State private var generation = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .id(generation)
            .onReceive(NotificationCenter.default.publisher(for: Feeqd.didReset)) { _ in generation += 1 }
    }
}

public struct FeeqdConfiguration: Sendable {
    public var apiKey: String
    /// Optional: saves a round trip at launch (the board otherwise comes from `/sdk/config`).
    public var boardID: String?
    /// Where reads and writes go. The defaults are production; point them at a local stack
    /// (go-reader and go-gatherer) only while developing Feeqd itself.
    public var readerURL: URL
    public var gathererURL: URL
    /// Wins over the colours set in the dashboard.
    public var theme: FeeqdTheme
    /// String overrides by key (`"board.title"`, `"submit.cta"`…). Win over the dashboard's copy.
    public var strings: [String: String]
    /// Defaults to the host app's `CFBundleShortVersionString`.
    public var appVersion: String?
    /// The chat button on the board. It only appears once the team has turned the chat on in the
    /// dashboard and the key carries chat, so leaving this on is safe; turn it off to offer the
    /// chat only through `Feeqd.ChatView()`.
    public var showsChatButton: Bool
    /// Read what the user pays from the App Store (StoreKit), so the dashboard can show the
    /// revenue behind each request. Off unless you turn it on: it is your app's data, and you
    /// declare "Purchase History" in your app's privacy details when you do. Read-only.
    public var collectPurchases: Bool
    /// The "See translation" button on requests and comments written in another language than
    /// the device's. Translated on the device by Apple's Translation framework: nothing leaves
    /// the phone. iOS 18 and later; before, it never shows.
    public var translation: FeeqdTranslation

    public init(
        apiKey: String,
        boardID: String? = nil,
        readerURL: URL = Feeqd.defaultReaderURL,
        gathererURL: URL = Feeqd.defaultGathererURL,
        theme: FeeqdTheme = FeeqdTheme(),
        strings: [String: String] = [:],
        appVersion: String? = nil,
        showsChatButton: Bool = true,
        collectPurchases: Bool = false,
        translation: FeeqdTranslation = .automatic
    ) {
        self.apiKey = apiKey
        self.boardID = boardID
        self.readerURL = readerURL
        self.gathererURL = gathererURL
        self.theme = theme
        self.strings = strings
        self.appVersion = appVersion
        self.showsChatButton = showsChatButton
        self.collectPurchases = collectPurchases
        self.translation = translation
    }
}

/// When the "See translation" button shows, for `FeeqdConfiguration.translation`.
public enum FeeqdTranslation: Sendable {
    /// On text whose language differs from the device's, when the device can translate it.
    case automatic
    /// Never.
    case hidden

    var mode: TranslationOffer.Mode {
        switch self {
        case .automatic: .automatic
        case .hidden: .hidden
        }
    }
}

/// What a user pays you outside the App Store, for `Feeqd.updateUser(payment:)`.
public enum FeeqdPayment: Sendable, Equatable {
    case weekly(Decimal, currency: String = "USD")
    case monthly(Decimal, currency: String = "USD")
    case yearly(Decimal, currency: String = "USD")
    /// A one-off purchase: shown apart, never counted as monthly revenue.
    case lifetime(Decimal, currency: String = "USD")

    var summary: PaymentSummary {
        switch self {
        case let .weekly(amount, currency): PaymentSummary(period: .week, amount: amount, currency: currency, source: .manual)
        case let .monthly(amount, currency): PaymentSummary(period: .month, amount: amount, currency: currency, source: .manual)
        case let .yearly(amount, currency): PaymentSummary(period: .year, amount: amount, currency: currency, source: .manual)
        case let .lifetime(amount, currency): PaymentSummary(period: .lifetime, amount: amount, currency: currency, source: .manual)
        }
    }
}

/// The answer of `Feeqd.chatStatus()`.
public struct FeeqdChatStatus: Sendable, Equatable {
    /// The key carries chat and the server answered.
    public let isAvailable: Bool
    /// The team wrote something this user has not seen.
    public let hasUnread: Bool

    public init(isAvailable: Bool, hasUnread: Bool) {
        self.isAvailable = isAvailable
        self.hasUnread = hasUnread
    }
}

/// Colours set in code. Anything left `nil` comes from the dashboard, then from the system.
///
/// Setting them here is the recommended way: they use your app's own colours and dark mode, and
/// they are there from the first frame, before the dashboard's arrive.
public struct FeeqdTheme: Sendable {
    public var primary: Color?
    public var background: Color?
    public var surface: Color?
    public var textPrimary: Color?
    public var textSecondary: Color?
    public var voteActive: Color?
    public var cornerRadius: CGFloat?
    /// The status badges' colours.
    public var statusColors: FeeqdStatusColors
    /// Rounded, serif or monospaced system font across every screen. Needs iOS 16.1.
    public var fontDesign: FeeqdFontDesign?

    public init(
        primary: Color? = nil,
        background: Color? = nil,
        surface: Color? = nil,
        textPrimary: Color? = nil,
        textSecondary: Color? = nil,
        voteActive: Color? = nil,
        cornerRadius: CGFloat? = nil,
        statusColors: FeeqdStatusColors = FeeqdStatusColors(),
        fontDesign: FeeqdFontDesign? = nil
    ) {
        self.primary = primary
        self.background = background
        self.surface = surface
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.voteActive = voteActive
        self.cornerRadius = cornerRadius
        self.statusColors = statusColors
        self.fontDesign = fontDesign
    }
}

/// Status badge colours. Statuses are named per board in the dashboard, but each one belongs to
/// one of three stages, so colouring the stages covers every board; `byStatus` picks out one
/// status by its slug (`"planned"`, `"in_progress"`…) and wins over its stage.
public struct FeeqdStatusColors: Sendable {
    /// Not started: pending, under review, planned.
    public var open: Color?
    public var inProgress: Color?
    /// Finished: done, shipped, declined.
    public var done: Color?
    public var byStatus: [String: Color]

    public init(open: Color? = nil, inProgress: Color? = nil, done: Color? = nil, byStatus: [String: Color] = [:]) {
        self.open = open
        self.inProgress = inProgress
        self.done = done
        self.byStatus = byStatus
    }
}

public enum FeeqdFontDesign: Sendable {
    case standard, rounded, serif, monospaced
}

extension ThemeOverrides {
    init(_ theme: FeeqdTheme) {
        var categories: [RemoteStatus.Category: Color] = [:]
        categories[.open] = theme.statusColors.open
        categories[.progress] = theme.statusColors.inProgress
        categories[.closed] = theme.statusColors.done
        self.init(
            primary: theme.primary,
            background: theme.background,
            surface: theme.surface,
            textPrimary: theme.textPrimary,
            textSecondary: theme.textSecondary,
            voteActive: theme.voteActive,
            cornerRadius: theme.cornerRadius,
            statusColors: theme.statusColors.byStatus,
            categoryColors: categories,
            fontDesign: theme.fontDesign.map(Font.Design.init)
        )
    }
}

extension Font.Design {
    init(_ design: FeeqdFontDesign) {
        switch design {
        case .standard: self = .default
        case .rounded: self = .rounded
        case .serif: self = .serif
        case .monospaced: self = .monospaced
        }
    }
}

/// Showing the screen before `configure` is the integrator's mistake: loud in debug, and an
/// empty view — never a crash — in a release build.
private struct NotConfiguredView: View {
    var body: some View {
        Color.clear.onAppear {
            assertionFailure("FeeqdKit: call Feeqd.configure(with:) before showing a Feeqd view.")
        }
    }
}
