import CMonero
import HsToolKit
import XCTest
@testable import MoneroKit

/// 25-word restores in every wallet2 language, through the real restore path
/// (`MoneroCore.prepare()` -> `createWalletFromCredentials` ->
/// `MONERO_WalletManager_recoveryWallet`).
///
/// wallet2 matches seed words byte for byte against its word lists, which are
/// NFC: `find_seed_language` looks up `utf8prefix(word, unique_prefix_length)`
/// in the trimmed word map, and `WordHash`/`WordEqual` only lower-case code
/// points, they do not normalize. Until October 2026 the legacy path sent the
/// phrase in NFKD, which split every accented, umlauted, dakuten and й/ё
/// character into a base letter plus a combining mark. A Spanish, German,
/// Japanese or Russian phrase with such a letter in a word's unique prefix
/// then failed with "Electrum-style word list failed verification", and the
/// app sat on "Connecting". The French, Esperanto, Dutch, Italian,
/// Portuguese, Lojban and English lists are ASCII, and NFKD leaves the
/// Chinese list as it is.
///
/// The phrases are `legacy-vectors.json`, shared with the Android suite
/// (app/src/test/resources): one valid phrase per wallet2 language with its
/// address from an independent oracle (keccak-256, ed25519 and Monero base58
/// over monero's `src/mnemonics` lists), plus a Spanish phrase that wallet2
/// restored on a device. A second oracle (Python, words decoded as in
/// `words_to_bytes`, spend key through `sc_reduce32`) agrees on all 14.
final class LegacyLanguageAddressTests: XCTestCase {

    struct Fixture: Decodable {
        let lang: String
        let source: String
        let phrase: String
        let address: String

        var words: [String] { phrase.split(separator: " ").map(String.init) }
    }

    static let vectors: [Fixture] = {
        guard let url = Bundle.module.url(forResource: "legacy-vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Fixture].self, from: data)) ?? []
    }()

    static func vector(_ lang: String, source: String = "oracle") throws -> Fixture {
        try XCTUnwrap(vectors.first { $0.lang == lang && $0.source == source }, "no \(source) vector for \(lang)")
    }

    func testVectorsCoverEveryWallet2Language() {
        let languages = Set(Self.vectors.filter { $0.source == "oracle" }.map(\.lang))
        XCTAssertEqual(languages, [
            "Chinese (simplified)", "English", "Dutch", "French", "Spanish", "German", "Italian",
            "Portuguese", "Japanese", "Russian", "Esperanto", "Lojban", "English (old)",
        ])
    }

    // MARK: - Every wallet2 language

    func testChineseSimplified() throws { assertRestores(.legacy, try Self.vector("Chinese (simplified)")) }
    func testEnglish() throws { assertRestores(.legacy, try Self.vector("English")) }
    func testDutch() throws { assertRestores(.legacy, try Self.vector("Dutch")) }
    func testFrench() throws { assertRestores(.legacy, try Self.vector("French")) }
    func testSpanish() throws { assertRestores(.legacy, try Self.vector("Spanish")) }
    func testSpanishRestoredByWallet2OnADevice() throws { assertRestores(.legacy, try Self.vector("Spanish", source: "wallet2")) }
    /// Holds all five Ä/Ö/Ü words of the list (Ästhetik, Ökologie, Ölberg,
    /// Ölkrise, Übermut) in list case.
    func testGerman() throws { assertRestores(.legacy, try Self.vector("German")) }
    func testItalian() throws { assertRestores(.legacy, try Self.vector("Italian")) }
    func testPortuguese() throws { assertRestores(.legacy, try Self.vector("Portuguese")) }
    func testJapanese() throws { assertRestores(.legacy, try Self.vector("Japanese")) }
    func testRussian() throws { assertRestores(.legacy, try Self.vector("Russian")) }
    func testEsperanto() throws { assertRestores(.legacy, try Self.vector("Esperanto")) }
    /// Holds words with an inner apostrophe.
    func testLojban() throws { assertRestores(.legacy, try Self.vector("Lojban")) }
    func testEnglishOld() throws { assertRestores(.legacy, try Self.vector("English (old)")) }

    func testEnglishGoldenIsUnchanged() { assertRestores(.legacy, Self.englishGolden) }

    // MARK: - Input forms

    /// Decomposed input (a combining mark after the base letter, as some
    /// keyboards and pasteboards deliver it) reaches wallet2 composed.
    func testDecomposedInputRestoresTheSameWallet() throws {
        for lang in ["Spanish", "German", "Japanese", "Russian"] {
            let fixture = try Self.vector(lang)
            let decomposed = Fixture(
                lang: lang + " (NFD)",
                source: fixture.source,
                phrase: fixture.phrase.decomposedStringWithCanonicalMapping,
                address: fixture.address
            )
            XCTAssertNotEqual(Array(decomposed.phrase.utf8), Array(fixture.phrase.utf8))
            assertRestores(.legacy, decomposed)
        }
    }

    /// wallet2 lower-cases both sides with `std::towlower`. In the C locale,
    /// which wallet2 runs in here and in the app, that maps ASCII only:
    /// "säbel" finds "Säbel", but "ästhetik" misses "Ästhetik". The app
    /// hands the kit every legacy word in its list form for this reason. If
    /// the second half starts to fail, wallet2's matching changed; the
    /// app's mapping stays harmless.
    func testWallet2LowerCasesAsciiOnly() throws {
        let german = try Self.vector("German")
        let asciiLowered = german.words.map { word in
            word.unicodeScalars.first?.isASCII == true ? word.lowercased() : word
        }
        XCTAssertNotEqual(asciiLowered, german.words)
        assertRestores(.legacy, Fixture(
            lang: "German (ASCII capitals lowered)",
            source: german.source,
            phrase: asciiLowered.joined(separator: " "),
            address: german.address
        ))

        let lowered = german.words.map { $0.lowercased() }
        let result = restore(.legacy(seed: lowered, passphrase: ""))
        XCTAssertNil(result.address, "lowercase Ä/Ö/Ü words now restore")
        XCTAssertTrue(result.error?.contains("Electrum-style word list failed verification") == true,
                      result.error ?? "no error")
    }

    // MARK: - Polyseed keeps its NFKD path

    /// Polyseed normalizes to NFKD itself (polyseed.c), and the kit still
    /// hands it NFKD. These reference vectors pin that path.
    func testPolyseedGoldensAreUnchanged() {
        assertRestores(.polyseed, Self.polyseedEnglish)
        assertRestores(.polyseed, Self.polyseedSpanish)
        assertRestores(.polyseed, Self.polyseedJapanese)
    }

    // MARK: - Helpers

    enum Kind { case legacy, polyseed }

    private func assertRestores(_ kind: Kind, _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        let wallet: MoneroWallet
        switch kind {
        case .legacy: wallet = .legacy(seed: fixture.words, passphrase: "")
        case .polyseed: wallet = .polyseed(seed: fixture.words, passphrase: "")
        }
        let result = restore(wallet)
        XCTAssertEqual(result.address, fixture.address,
                       "\(fixture.lang): restore gave \(result.error ?? "a different address")",
                       file: file, line: line)
    }

    /// Restores `wallet` into a temporary directory and returns its primary
    /// address, or the wallet2 error.
    private func restore(_ wallet: MoneroWallet) -> (address: String?, error: String?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyLanguageAddressTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let core = MoneroCore(
            wallet: wallet,
            account: 0,
            walletPath: directory.appendingPathComponent("wallet").path,
            walletPassword: "pw",
            node: Node(url: URL(string: "https://node.monero.one:443")!, isTrusted: false),
            restoreHeight: 0,
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: 0
        )
        core.prepare()
        defer { core.stop() }

        guard let pointer = core.getWalletPointer() else {
            return (nil, "\(core.state)")
        }
        return (stringFromCString(MONERO_Wallet_address(pointer, 0, 0)), nil)
    }

    // MARK: - Goldens

    /// polyseed `ref_en1` reference vector.
    static let polyseedEnglish = Fixture(
        lang: "English",
        source: "golden",
        phrase: "raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy airport language",
        address: "47AjPj7DVPQVGGXJXbbTMZWcKQDejGHYZChVkeujy8qPLjKkgdsxge4DzvkRMgU4sDUigGLuBN9stKBMowhuXH2HJHWAuRf"
    )

    /// polyseed `ref_es1` reference vector.
    static let polyseedSpanish = Fixture(
        lang: "Spanish",
        source: "golden",
        phrase: "eje fin parte célebre tabú pestaña lienzo puma prisión hora regalo lengua existir lápiz lote sonoro",
        address: "44ozexdtsDZ9SiLwQvdpp7PZgaRNUJjqaAjU9iZWSri6fjM6JjshqPCSLBf5MHspanHbHS1u9mLXLHsv6ngiyzBbTUuQPVS"
    )

    /// polyseed `rand_Japanese_0` reference vector.
    static let polyseedJapanese = Fixture(
        lang: "Japanese",
        source: "golden",
        phrase: "わじまし ぎしき なふだ みんか たまご ぎゅうにく もんだい かいが まかい あてはまる あいこくしん めした ふつう くつした むすこ みつける",
        address: "48PtJ24bTtU66MZbw72xgnVe3EQbiKHgVYy3VgNoceR1KzrganVKh4dgKF5xmKEpQyXuhZi6yDwjQfpx5CJM7kTc495GtZD"
    )

    /// The English vector the app and Android suites pin.
    static let englishGolden = Fixture(
        lang: "English",
        source: "golden",
        phrase: "sequence atlas unveil summon pebbles tuesday beer rudely snake rockets different fuselage woven tagged bested dented vegan hover rapid fawns obvious muppet randomly seasons randomly",
        address: "46PAiPrNjr2XS82k2ovp5EUYLzBt9pYNW2LXUFsZiv8S3Mt21FZ5qQaAroko1enzw3eGr9qC7X1D7Geoo2RrAotYPvzt9vB"
    )
}
