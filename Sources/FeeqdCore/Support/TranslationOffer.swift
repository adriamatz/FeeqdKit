import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// When a text earns a "See translation": it is written in another language than the one the
/// user reads, and the language is clear enough to translate from.
///
/// Only the decision lives here. Whether the device can translate that pair, and the
/// translation itself, are the screen's (Apple's Translation framework, iOS 18).
package enum TranslationOffer {
    package enum Mode: Sendable {
        /// Offered when the text's language differs from the reader's.
        case automatic
        /// Never offered.
        case hidden
    }

    /// Below this the recognizer is guessing: "OK" reads as Polish, "Dark mode" as anything.
    /// A short title it is unsure of shows no button rather than a wrong one.
    static let minimumConfidence = 0.5

    /// The language the user reads: the device's first preferred language.
    package static var readerLanguage: String { Locale.preferredLanguages.first ?? "en" }

    /// The language to translate `text` from, or nil when there is nothing to offer: hidden by
    /// the integrator, already in the reader's language, or a language too unclear to name.
    package static func sourceLanguage(of text: String, readerLanguage: String, mode: Mode) -> String? {
        guard mode == .automatic, let detected = detectedLanguage(of: text) else { return nil }
        return baseLanguage(detected) == baseLanguage(readerLanguage) ? nil : detected
    }

    /// The text's dominant language (`"es"`, `"pt"`, `"zh-Hans"`), when the recognizer is sure enough.
    package static func detectedLanguage(of text: String) -> String? {
        #if canImport(NaturalLanguage)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence,
              language != .undetermined else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }

    /// `es-MX` → `es`, `pt_BR` → `pt`: a Mexican reader reads Spanish from Spain just fine.
    static func baseLanguage(_ tag: String) -> String {
        (tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag).lowercased()
    }
}
