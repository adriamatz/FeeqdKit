import FeeqdCore
import SwiftUI
#if canImport(Translation)
@preconcurrency import Translation
#endif

/// Texts that can be read in the user's language, with the small "See translation" button that
/// switches them. Translated on the device, nothing goes to a server; before iOS 18 the button
/// never shows and the texts stay as written.
///
/// `content` gets the texts to show (the originals, or the translation once asked for) and the
/// button, to place it where it reads best.
struct Translatable<Content: View>: View {
    let texts: [String]
    /// The spacing of the stack the texts would otherwise sit in.
    var spacing: CGFloat
    @ViewBuilder let content: (_ shown: [String], _ button: TranslateButton) -> Content

    @State private var source: String?
    @State private var translation: [String]?
    @State private var showsTranslation = false

    @Environment(\.feeqdTranslation) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content(
                showsTranslation ? translation ?? texts : texts,
                TranslateButton(texts: texts, source: source, translation: $translation, showsTranslation: $showsTranslation)
            )
        }
        .task(id: texts) { source = await TranslateButton.offer(for: texts, mode: mode) }
    }
}

/// Nothing at all until there is a translation to offer.
struct TranslateButton: View {
    let texts: [String]
    /// The language to translate from, once it is known the device can.
    let source: String?
    @Binding var translation: [String]?
    @Binding var showsTranslation: Bool

    var body: some View {
        #if canImport(Translation)
        if #available(iOS 18.0, macOS 15.0, *), let source {
            OnDeviceTranslateButton(texts: texts, source: source, translation: $translation, showsTranslation: $showsTranslation)
        }
        #endif
    }

    /// The source language when the texts are in another language than the reader's and the
    /// device can translate between the two (a pair it has yet to download counts: the system
    /// offers the download).
    static func offer(for texts: [String], mode: TranslationOffer.Mode) async -> String? {
        let reader = TranslationOffer.readerLanguage
        guard let source = TranslationOffer.sourceLanguage(of: texts.joined(separator: "\n"), readerLanguage: reader, mode: mode)
        else { return nil }
        #if canImport(Translation)
        if #available(iOS 18.0, macOS 15.0, *) {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: reader))
            return status == .unsupported ? nil : source
        }
        #endif
        return nil
    }
}

#if canImport(Translation)
@available(iOS 18.0, macOS 15.0, *)
private struct OnDeviceTranslateButton: View {
    let texts: [String]
    let source: String
    @Binding var translation: [String]?
    @Binding var showsTranslation: Bool

    @State private var configuration: TranslationSession.Configuration?

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        Button(showsTranslation ? strings(.translateOriginal) : strings(.translateSee), action: toggle)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .buttonStyle(.borderless)
            .translationTask(configuration) { session in
                // A failure (no network to download the languages, the user declined it) leaves
                // the originals on screen; another tap tries again.
                guard let translated = await Self.translate(texts, with: session) else { return }
                translation = translated
                showsTranslation = true
            }
    }

    /// The texts in the reader's language, in the same order; nil when the session failed.
    /// Off the main actor: the session's work is the framework's, not the screen's.
    private nonisolated static func translate(_ texts: [String], with session: TranslationSession) async -> [String]? {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        guard let responses = try? await session.translations(from: requests) else { return nil }
        var translated = texts
        for response in responses {
            if let index = response.clientIdentifier.flatMap(Int.init), translated.indices.contains(index) {
                translated[index] = response.targetText
            }
        }
        return translated
    }

    private func toggle() {
        if showsTranslation {
            showsTranslation = false
        } else if translation != nil {
            // Translated once already: back to it without another session.
            showsTranslation = true
        } else if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: source),
                target: Locale.Language(identifier: TranslationOffer.readerLanguage)
            )
        } else {
            configuration?.invalidate()
        }
    }
}
#endif
