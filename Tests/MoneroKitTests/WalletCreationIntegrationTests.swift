import CMonero
import XCTest
@testable import MoneroKit

/// End-to-end wallet creation through the real wallet2 library, one test per
/// seed type. This is the guard the null-key burn bug lacked: a library
/// rebuild that silently breaks any creation path (May 2026: `bytesToWords`
/// stubbed to "" broke every BIP39 wallet) now fails CI instead of shipping
/// a wallet whose Receive screen shows the burn address.
///
/// No network is involved — wallet2's generate/recover paths are pure
/// filesystem + crypto.
final class WalletCreationIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var wm: UnsafeMutableRawPointer!
    private var openWallets: [UnsafeMutableRawPointer] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalletCreationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        wm = MONERO_WalletManagerFactory_getWalletManager()
        XCTAssertNotNil(wm)
    }

    override func tearDownWithError() throws {
        for wallet in openWallets {
            MONERO_WalletManager_closeWallet(wm, wallet, false)
        }
        openWallets = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func walletPath(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }

    private func track(_ wallet: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        if let wallet { openWallets.append(wallet) }
        return wallet
    }

    private func address(_ wallet: UnsafeMutableRawPointer) -> String {
        stringFromCString(MONERO_Wallet_address(wallet, 0, 0)) ?? ""
    }

    /// The invariants every freshly created wallet must satisfy. Their
    /// combined violation was the burn bug: status error, null address,
    /// zero view key.
    private func assertHealthy(_ wallet: UnsafeMutableRawPointer?, _ label: String) {
        guard let wallet else { return XCTFail("\(label): wallet pointer is nil") }
        XCTAssertEqual(MONERO_Wallet_status(wallet), 0, "\(label): wallet2 status is an error")
        let addr = address(wallet)
        XCTAssertFalse(addr.isEmpty, "\(label): empty address")
        XCTAssertFalse(NullKeyAddress.isNullKey(addr), "\(label): NULL-KEY BURN ADDRESS — keys never loaded")
        XCTAssertTrue(MONERO_Wallet_addressValid(addr, 0), "\(label): address fails wallet2 validation")
        let viewKey = stringFromCString(MONERO_Wallet_secretViewKey(wallet))
        XCTAssertNotEqual(viewKey, NullKeyAddress.zeroSecretKey, "\(label): all-zero view key")
    }

    // MARK: - Seed types

    func testBip39CreationYieldsHealthyWallet() throws {
        let mnemonic = Array(repeating: "abandon", count: 23) + ["art"]
        let spendKeyHex = try spendKeyHexFromBip39(mnemonic: mnemonic, passphrase: "")

        let wallet = track(MONERO_WalletManager_createDeterministicWalletFromSpendKey(
            wm, walletPath("bip39"), "pw", "English", 0, 0, spendKeyHex, 1
        ))
        assertHealthy(wallet, "bip39")

        // Golden address for the vector mnemonic. Pins the full
        // seed → spend key → wallet2 keys → address chain; if this moves,
        // every 24-word wallet restores to a different (empty) wallet.
        XCTAssertEqual(
            address(wallet!),
            "43Xuqb8woKbELkxbc4U8ZEMk87rx8VingbtWmxXpFiJK6mKHJuK8bGGTrndC4y6DmGPdwQDyJaWgu6ZXCKNfeoRSVMTUBCX"
        )
    }

    func testLegacySeedRoundTrip() throws {
        // Source wallet from the bip39 vector, export its 25-word legacy
        // seed, recover a second wallet from those words — addresses must
        // match. Exercises wallet2's words_to_bytes decode path.
        let mnemonic = Array(repeating: "abandon", count: 23) + ["art"]
        let spendKeyHex = try spendKeyHexFromBip39(mnemonic: mnemonic, passphrase: "")
        let source = track(MONERO_WalletManager_createDeterministicWalletFromSpendKey(
            wm, walletPath("legacy-src"), "pw", "English", 0, 0, spendKeyHex, 1
        ))
        assertHealthy(source, "legacy round-trip source")

        let seedWords = stringFromCString(MONERO_Wallet_seed(source!, "")) ?? ""
        XCTAssertEqual(seedWords.split(separator: " ").count, 25, "legacy seed export")

        let recovered = track(MONERO_WalletManager_recoveryWallet(
            wm, walletPath("legacy-dst"), "pw", seedWords, 0, 0, 1, ""
        ))
        assertHealthy(recovered, "legacy recovery")
        XCTAssertEqual(address(source!), address(recovered!), "legacy restore diverged from source wallet")
    }

    func testPolyseedCreationYieldsHealthyWallet() throws {
        let seedWords = stringFromCString(MONERO_Wallet_createPolyseed("English")) ?? ""
        XCTAssertEqual(seedWords.split(separator: " ").count, 16, "polyseed generation")

        let wallet = track(MONERO_WalletManager_createWalletFromPolyseed(
            wm, walletPath("polyseed"), "pw", 0, seedWords, "", false, 0, 1
        ))
        assertHealthy(wallet, "polyseed")
    }

    // MARK: - Failure-mode documentation

    /// wallet2's failure shape that started it all: recovery from an empty
    /// mnemonic returns a NON-null wallet whose status is an error and whose
    /// address is the null-key burn address. If wallet2 ever changes this,
    /// we want to know; until then, this is why open/create paths must
    /// check status and never serve an unchecked wallet to the UI.
    func testEmptySeedRecoveryProducesTheBurnAddress() {
        let wallet = track(MONERO_WalletManager_recoveryWallet(
            wm, walletPath("broken"), "pw", "", 0, 0, 1, ""
        ))
        guard let wallet else { return XCTFail("expected non-null pointer with error status") }
        XCTAssertNotEqual(MONERO_Wallet_status(wallet), 0, "empty-seed recovery should be an error")
        XCTAssertEqual(address(wallet), NullKeyAddress.mainnet,
                       "error-status wallet should render the null-key address (the burn bug's mechanism)")
    }
}
