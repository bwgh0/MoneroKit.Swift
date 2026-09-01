import XCTest
@testable import MoneroKit

/// Golden tests for the BIP39 → Monero spend-key derivation
/// (PBKDF2 → BIP44 m/44'/128'/0'/0/0 secp256k1 → reduce mod ed25519 l).
///
/// This derivation defines every `.bip39` wallet's keys. If it drifts, every
/// 24-word wallet restores to a different (empty) wallet. The expected value
/// was computed with an independent Python implementation of the same
/// scheme, not with this code — a shared bug can't hide in the fixture.
///
/// Context: BIP39 creation silently broke in May 2026 when a library rebuild
/// stubbed `Wallet::bytesToWords` to return "" — wallet2 then recovered from
/// an empty mnemonic and produced a keyless wallet whose Receive screen
/// showed the null-key burn address. Creation now bypasses the words
/// round-trip and hands wallet2 this spend key directly, so this test is the
/// contract for that path.
final class Bip39DerivationTests: XCTestCase {

    private let vectorMnemonic =
        Array(repeating: "abandon", count: 23) + ["art"]

    func testSpendKeyHexGoldenVector() throws {
        let spendKeyHex = try spendKeyHexFromBip39(mnemonic: vectorMnemonic, passphrase: "")
        XCTAssertEqual(
            spendKeyHex,
            "4fe2e8fa6ad56846a4b70b5cf85a8a5ff310d8eb5daaf5b11af9591d79fc0a02"
        )
    }

    func testPassphraseChangesTheKey() throws {
        let withPassphrase = try spendKeyHexFromBip39(mnemonic: vectorMnemonic, passphrase: "x")
        let without = try spendKeyHexFromBip39(mnemonic: vectorMnemonic, passphrase: "")
        XCTAssertNotEqual(withPassphrase, without)
        XCTAssertEqual(withPassphrase.count, 64)
    }

    /// `legacySeedFromBip39` rides the fork-only `bytesToWords`; when a
    /// library build stubs it to "", the conversion must throw rather than
    /// hand wallet2 an empty mnemonic (that path is how the keyless-wallet
    /// burn bug started).
    func testLegacySeedNeverReturnsEmpty() {
        do {
            let words = try legacySeedFromBip39(mnemonic: vectorMnemonic, passphrase: "")
            XCTAssertFalse(words.isEmpty)
            XCTAssertEqual(words.split(separator: " ").count, 25)
        } catch {
            // Throwing is the correct outcome on builds with the stub.
        }
    }
}
