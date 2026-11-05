import FeeqdCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Everything the screens need from the integrator, built once by `Feeqd.configure`.
package struct FeeqdContext: Sendable {
    package let client: FeeqdClient
    package let preferredBoardID: String?
    package let strings: StringTable
    package let themeOverrides: ThemeOverrides
    /// Whether the board offers the chat. Even when true, the button only shows once the
    /// server confirmed the chat works for this key.
    package let showsChatButton: Bool
    /// The "See translation" button on requests and comments.
    package let translation: TranslationOffer.Mode

    package init(
        client: FeeqdClient,
        preferredBoardID: String?,
        strings: StringTable,
        themeOverrides: ThemeOverrides,
        showsChatButton: Bool = true,
        translation: TranslationOffer.Mode = .automatic
    ) {
        self.client = client
        self.preferredBoardID = preferredBoardID
        self.strings = strings
        self.themeOverrides = themeOverrides
        self.showsChatButton = showsChatButton
        self.translation = translation
    }
}

/// Colours set in code. They win over the dashboard's, which win over the system's.
package struct ThemeOverrides: Sendable {
    package var primary: Color?
    package var background: Color?
    package var surface: Color?
    package var textPrimary: Color?
    package var textSecondary: Color?
    package var voteActive: Color?
    package var cornerRadius: CGFloat?
    /// By status slug; wins over `categoryColors`.
    package var statusColors: [String: Color]
    package var categoryColors: [RemoteStatus.Category: Color]
    package var fontDesign: Font.Design?

    package init(
        primary: Color? = nil,
        background: Color? = nil,
        surface: Color? = nil,
        textPrimary: Color? = nil,
        textSecondary: Color? = nil,
        voteActive: Color? = nil,
        cornerRadius: CGFloat? = nil,
        statusColors: [String: Color] = [:],
        categoryColors: [RemoteStatus.Category: Color] = [:],
        fontDesign: Font.Design? = nil
    ) {
        self.primary = primary
        self.background = background
        self.surface = surface
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.voteActive = voteActive
        self.cornerRadius = cornerRadius
        self.statusColors = statusColors
        self.categoryColors = categoryColors
        self.fontDesign = fontDesign
    }
}

/// The colours a screen actually uses.
///
/// Each one falls back to a system colour when neither the code nor the dashboard sets it, so
/// an unconfigured SDK looks like part of the app rather than a widget pasted on top.
package struct ResolvedTheme {
    package var primary: Color
    package var background: Color
    package var surface: Color
    package var textPrimary: Color
    package var textSecondary: Color
    package var voteActive: Color
    package var cornerRadius: CGFloat
    package var fontDesign: Font.Design?
    private var statusOverrides: [String: Color]
    private var categoryOverrides: [RemoteStatus.Category: Color]

    package init(config: SDKConfig, overrides: ThemeOverrides) {
        func remote(_ name: String) -> Color? { config.colors[name].flatMap(Color.init(feeqdPair:)) }
        primary = overrides.primary ?? remote("primary") ?? .accentColor
        background = overrides.background ?? remote("background") ?? .feeqdGroupedBackground
        surface = overrides.surface ?? remote("surface") ?? .feeqdSecondaryGroupedBackground
        textPrimary = overrides.textPrimary ?? remote("textPrimary") ?? .primary
        textSecondary = overrides.textSecondary ?? remote("textSecondary") ?? .secondary
        voteActive = overrides.voteActive ?? remote("voteActive") ?? primary
        cornerRadius = overrides.cornerRadius ?? config.cornerRadius.map { CGFloat($0) } ?? 12
        fontDesign = overrides.fontDesign
        statusOverrides = overrides.statusColors
        categoryOverrides = overrides.categoryColors
    }

    /// A status's colour: the code's for that status, then the code's for its category, then
    /// the one the dashboard gave it, then grey.
    package func color(for status: RemoteStatus?, slug: String) -> Color {
        if let color = statusOverrides[status?.slug ?? slug] { return color }
        if let status, let color = categoryOverrides[status.category] { return color }
        return status?.color.flatMap { Color(feeqdPair: $0) } ?? .secondary
    }
}

extension View {
    /// The integrator's font design across every screen. `fontDesign` needs iOS 16.1; on 16.0
    /// the system font stays.
    @ViewBuilder
    package func feeqdFontDesign(_ design: Font.Design?) -> some View {
        if let design, #available(iOS 16.1, macOS 13.0, *) {
            fontDesign(design)
        } else {
            self
        }
    }
}

extension Color {
    /// A colour that follows light and dark mode, from the server's resolved hex pair.
    package init?(feeqdPair pair: ColorPair) {
        guard let light = HexColor.parse(pair.light) else { return nil }
        let dark = HexColor.parse(pair.dark) ?? light
        #if canImport(UIKit)
        self = Color(uiColor: UIColor { traits in
            UIColor(feeqd: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(feeqd: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #endif
    }

    static var feeqdGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var feeqdSecondaryGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(feeqd rgba: RGBA) {
        self.init(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
#elseif canImport(AppKit)
extension NSColor {
    convenience init(feeqd rgba: RGBA) {
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
#endif

private struct StringsKey: EnvironmentKey {
    static let defaultValue = StringTable()
}

private struct TranslationKey: EnvironmentKey {
    static let defaultValue = TranslationOffer.Mode.automatic
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme(config: .fallback, overrides: ThemeOverrides())
}

extension EnvironmentValues {
    var feeqdStrings: StringTable {
        get { self[StringsKey.self] }
        set { self[StringsKey.self] = newValue }
    }

    var feeqdTheme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var feeqdTranslation: TranslationOffer.Mode {
        get { self[TranslationKey.self] }
        set { self[TranslationKey.self] = newValue }
    }
}

extension ToolbarItemPlacement {
    /// The top-left corner on iOS; macOS has no navigation bar.
    static var feeqdLeading: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarLeading
        #else
        .automatic
        #endif
    }
}

extension View {
    /// Inline titles on iOS; macOS has no such thing.
    @ViewBuilder
    /// The title small and centred, on a bar of the theme's background: the system's own bar is
    /// white in light mode and black in dark, whatever the app's colours.
    func feeqdInlineTitle(_ theme: ResolvedTheme) -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    /// The search out of the way: browsing is what the screen is for. On iOS 26 a magnifier at
    /// the top trailing corner, next to the add button, when the bar has room for it (iOS would put
    /// it at the bottom); otherwise a field that hides once the list scrolls.
    @ViewBuilder
    func feeqdSearchable(text: Binding<String>, prompt: String, asButton: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26, *), asButton {
            // A magnifier in the bar that opens the field.
            searchable(text: text, prompt: prompt)
                .searchToolbarBehavior(.minimize)
                .toolbar { DefaultToolbarItem(kind: .search, placement: .topBarTrailing) }
        } else {
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
        }
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }

    /// Rows straight on the screen's background, a hairline between them. A List paints the
    /// system background behind its rows, black in dark mode whatever the app's colours, so it
    /// is hidden and the theme's drawn instead. The rows need `.listRowBackground` too.
    func feeqdRowList(_ theme: ResolvedTheme) -> some View {
        listStyle(.plain)
            .feeqdListBackground(theme)
    }

    /// A List on the theme's background instead of the system's.
    func feeqdListBackground(_ theme: ResolvedTheme) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
    }

    /// A message field in the theme's colours. The system's rounded border paints its own
    /// background, black in dark mode whatever the app's colours.
    func feeqdComposerField(_ theme: ResolvedTheme) -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.textSecondary.opacity(0.25), lineWidth: 0.5)
            )
    }

    /// The bar a composer sits in, on the theme's background.
    func feeqdComposerBar(_ theme: ResolvedTheme) -> some View {
        padding(.horizontal)
            .padding(.vertical, 10)
            .background(theme.background)
            .overlay(alignment: .top) { Divider() }
    }
}

/// The message for an error, in the user's words.
func feeqdMessage(for error: FeeqdError, strings: StringTable) -> String {
    switch error {
    case .identityRequired: return strings(.submitAnonymousNotAllowed)
    case .rateLimited: return strings(.rateLimited)
    case .quotaExceeded: return strings(.chatQuotaExceeded)
    case .server(_, .some("message_too_long"), _): return strings(.chatTooLong)
    default: return strings(.errorMessage)
    }
}
