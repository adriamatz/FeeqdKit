import FeeqdCore
import XCTest

/// When "See translation" shows. Titles taken from a real board, in the languages its users write in.
final class TranslationOfferTests: XCTestCase {
    func testOfferedForAnotherLanguage() {
        XCTAssertEqual(offer("Importar de outros apps", reader: "en-US"), "pt")
        XCTAssertEqual(offer("Gelesen Status zurückdatiern", reader: "es-ES"), "de")
        XCTAssertEqual(offer("Sería genial poder exportar mis libros", reader: "en"), "es")
        XCTAssertEqual(offer("Ability to Use Two Auto-Organize Tags", reader: "es-ES"), "en")
    }

    func testNotOfferedInTheReadersLanguage() {
        XCTAssertNil(offer("Ability to Use Two Auto-Organize Tags", reader: "en-GB"))
        XCTAssertNil(offer("Sería genial poder exportar mis libros", reader: "es-MX"), "a regional variant reads its base language")
        XCTAssertNil(offer("Sería genial poder exportar mis libros", reader: "es_419"))
    }

    func testNotOfferedWhenTheLanguageIsAGuess() {
        XCTAssertNil(offer("OK", reader: "es-ES"))
        XCTAssertNil(offer("Link kindle", reader: "es-ES"), "a product name is no language")
        XCTAssertNil(offer("   ", reader: "es-ES"))
        XCTAssertNil(offer("", reader: "es-ES"))
    }

    func testHiddenNeverOffers() {
        XCTAssertNil(TranslationOffer.sourceLanguage(of: "Importar de outros apps", readerLanguage: "en", mode: .hidden))
    }

    func testTitleAndDescriptionTogetherAreClearerThanTheTitle() {
        XCTAssertNil(offer("Dark mode", reader: "es-ES"))
        XCTAssertEqual(offer("Dark mode\nPlease add a dark theme for reading at night", reader: "es-ES"), "en")
    }

    private func offer(_ text: String, reader: String) -> String? {
        TranslationOffer.sourceLanguage(of: text, readerLanguage: reader, mode: .automatic)
    }
}
