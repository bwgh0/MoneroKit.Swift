import CMonero
import HsToolKit
import XCTest
@testable import MoneroKit

/// `signMessage(_:subaddress:)` against real wallet2 objects with no daemon
/// (the node URL points at a closed local port). The wallets are throwaway
/// wallets in this test's temporary folder, made from public BIP39 test
/// seeds. Never send funds to their addresses.
///
/// Cross-check: each run prints `SIGN_MESSAGE_VECTOR` lines. Write the
/// message to a file with no newline, open any wallet in Homebrew
/// `monero-wallet-cli --offline`, and run
/// `verify <file> <subaddress> <signature>`.
final class SignMessageTests: XCTestCase {
    /// The BIP39 vector of WalletCreationIntegrationTests.
    private static let ownerSeed = Array(repeating: "abandon", count: 23) + ["art"]
    /// The BIP39 vector "legal winner ... title": another wallet.
    private static let otherSeed = """
        legal winner thank year wave sausage worth useful legal winner thank year \
        wave sausage worth useful legal winner thank year wave sausage worth title
        """.components(separatedBy: " ")

    /// An owner-signature message: a tag, a colon and a SHA-256 in lowercase
    /// hex (here the hash of "test").
    private static let message = "oah/genesis/v1:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    /// Subaddress (0,1) of the owner wallet.
    private static let ownerSubaddress =
        "84SRAaUXDrhfxRo41T7TGD8WKCC3w6VjZW7uVLTMU7BLgqHnn2t59MW1qkhGU1rsC8bhsswDJaLyeQ9qbybxKWHq6PKnQc4"
    /// A signature from this kit for `message` and `ownerSubaddress`.
    /// Homebrew monero-wallet-cli v0.18.4.6 (offline) verified it: "Good
    /// signature ... with spend key". wallet2 uses a random nonce, so each
    /// run signs differently.
    private static let cliVerifiedSignature =
        "SigV2b2vnRhMDHTnCNvC15RStg9QinLbzFD7RcJLCNayqRUHMDdSghQ7csmR59Jd2RAVM34cANWpnPECUPf1ygUxaUe9V"
    /// The owner wallet's primary key pair under the mainnet subaddress tag
    /// (42), with a valid checksum. wallet2 finds index (0,0) for it.
    private static let primaryKeysAsSubaddress =
        "84N4AxnnPk1ELkxbc4U8ZEMk87rx8VingbtWmxXpFiJK6mKHJuK8bGGTrndC4y6DmGPdwQDyJaWgu6ZXCKNfeoRSVLmG6vD"

    private var tempDir: URL!
    private var cores: [MoneroCore] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignMessageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for core in cores {
            core.stop()
        }
        cores = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openWallet(_ wallet: MoneroWallet, name: String, networkType: NetworkType = .mainnet) throws -> MoneroCore {
        let core = MoneroCore(
            wallet: wallet,
            account: 0,
            walletPath: tempDir.appendingPathComponent(name).path,
            walletPassword: "pw",
            // Nothing listens on port 1, so no daemon call can succeed.
            node: Node(url: URL(string: "http://localhost:1")!, isTrusted: false),
            restoreHeight: 0,
            networkType: networkType,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: nil
        )
        cores.append(core)
        core.prepare()
        XCTAssertNotNil(core.getWalletPointer(), "\(name): wallet did not open")
        return core
    }

    private func openOwner() throws -> MoneroCore {
        try openWallet(.bip39(seed: Self.ownerSeed, passphrase: ""), name: "owner")
    }

    private func subaddress(_ core: MoneroCore, _ major: UInt64, _ minor: UInt64) throws -> String {
        let wallet = try XCTUnwrap(core.getWalletPointer())
        return try XCTUnwrap(stringFromCString(MONERO_Wallet_address(wallet, major, minor)))
    }

    private func assertRefused(_ expected: SignMessageError, file: StaticString = #filePath, line: UInt = #line,
                               _ work: () throws -> String) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual(error as? SignMessageError, expected, file: file, line: line)
        }
    }

    // MARK: - Signs

    func testSubaddressSignatureIsSigV2AndPassesTheSelfCheck() throws {
        let core = try openOwner()
        let wallet = try XCTUnwrap(core.getWalletPointer())
        XCTAssertEqual(core.address(index: 1), Self.ownerSubaddress, "subaddress (0,1) of the test seed moved")
        XCTAssertTrue(MONERO_Wallet_verifySignedMessage(wallet, Self.message, Self.ownerSubaddress, Self.cliVerifiedSignature))

        for (major, minor) in [(UInt64(0), UInt64(1)), (1, 0), (3, 7)] {
            let address = try subaddress(core, major, minor)
            let signature = try core.signMessage(Self.message, subaddress: address)
            XCTAssertTrue(signature.hasPrefix("SigV2"))
            XCTAssertEqual(signature.count, 93, "SigV2 and the base58 of a 64-byte signature")
            XCTAssertTrue(MONERO_Wallet_verifySignedMessage(wallet, Self.message, address, signature))
            print("SIGN_MESSAGE_VECTOR index=(\(major),\(minor)) message=\(Self.message) subaddress=\(address) signature=\(signature)")
        }

        // The signature binds the subaddress and the message.
        let address = try subaddress(core, 0, 1)
        let nextAddress = try subaddress(core, 0, 2)
        let signature = try core.signMessage(Self.message, subaddress: address)
        XCTAssertFalse(MONERO_Wallet_verifySignedMessage(wallet, Self.message, nextAddress, signature))
        XCTAssertFalse(MONERO_Wallet_verifySignedMessage(wallet, Self.message, core.address(index: 0), signature))
        XCTAssertFalse(MONERO_Wallet_verifySignedMessage(wallet, Self.message + "0", address, signature))
    }

    func testMessagesAtTheLimitsSign() throws {
        let core = try openOwner()
        let address = try subaddress(core, 0, 1)
        let printable = String(decoding: Array(UInt8(0x20) ... UInt8(0x7E)), as: UTF8.self)
        for message in ["", printable, String(repeating: "a", count: 1024)] {
            let signature = try core.signMessage(message, subaddress: address)
            XCTAssertTrue(signature.hasPrefix("SigV2"), "\(message.utf8.count)-byte message")
        }
    }

    // MARK: - Refusals

    func testNonAsciiAndControlMessagesRefuse() throws {
        let core = try openOwner()
        let address = try subaddress(core, 0, 1)
        let messages = ["héllo", "emoji 🙂", "nul\u{0}inside", "line\nbreak", "tab\tinside", "del\u{7F}",
                        String(repeating: "a", count: 1025)]
        for message in messages {
            assertRefused(.invalidMessage) { try core.signMessage(message, subaddress: address) }
        }
    }

    func testViewOnlyWalletRefuses() throws {
        let core = try openOwner()
        let viewKey = try XCTUnwrap(core.secretViewKey)
        let viewOnly = try openWallet(.watch(address: core.address(index: 0), viewKey: viewKey), name: "view-only")
        XCTAssertTrue(viewOnly.isWatchOnly)
        let address = try subaddress(viewOnly, 0, 1)
        let ownerAddress = try subaddress(core, 0, 1)
        XCTAssertEqual(address, ownerAddress, "the view-only wallet has the same subaddress")

        assertRefused(.viewOnlyWallet) { try viewOnly.signMessage(Self.message, subaddress: address) }
    }

    func testAnotherWalletsSubaddressRefuses() throws {
        let core = try openOwner()
        let other = try openWallet(.bip39(seed: Self.otherSeed, passphrase: ""), name: "other")
        let foreign = try subaddress(other, 0, 1)
        XCTAssertTrue(MONERO_Wallet_addressValid(foreign, 0))

        assertRefused(.notOwnSubaddress) { try core.signMessage(Self.message, subaddress: foreign) }
    }

    /// wallet2 alone signs for all three addresses with the primary spend
    /// key, and its verification accepts the result. The kit refuses them.
    func testPrimaryKeysRefuseInEveryEncoding() throws {
        let core = try openOwner()
        let wallet = try XCTUnwrap(core.getWalletPointer())
        let integrated = try XCTUnwrap(stringFromCString(MONERO_Wallet_integratedAddress(wallet, "0123456789abcdef")))
        XCTAssertEqual(integrated.count, 106)
        XCTAssertTrue(MONERO_Wallet_addressValid(Self.primaryKeysAsSubaddress, 0))

        for address in [core.address(index: 0), integrated, Self.primaryKeysAsSubaddress] {
            let raw = stringFromCString(MONERO_Wallet_signMessage(wallet, Self.message, address)) ?? ""
            XCTAssertTrue(MONERO_Wallet_verifySignedMessage(wallet, Self.message, address, raw),
                          "wallet2 signs for \(address.prefix(12)) with the primary key")

            assertRefused(.notOwnSubaddress) { try core.signMessage(Self.message, subaddress: address) }
        }
    }

    func testOtherNetworkAndMalformedAddressesRefuse() throws {
        let core = try openOwner()
        let testnet = try openWallet(.bip39(seed: Self.ownerSeed, passphrase: ""), name: "testnet", networkType: .testnet)
        let testnetSubaddress = try subaddress(testnet, 0, 1)
        let address = try subaddress(core, 0, 1)
        let badChecksum = String(address.dropLast()) + (address.hasSuffix("2") ? "3" : "2")

        for candidate in [testnetSubaddress, badChecksum, "", "not an address", address + "\u{0}", " " + address] {
            assertRefused(.notOwnSubaddress) { try core.signMessage(Self.message, subaddress: candidate) }
        }
    }

    func testClosedWalletRefuses() throws {
        let core = try openOwner()
        let address = try subaddress(core, 0, 1)
        core.stop()

        assertRefused(.walletNotOpen) { try core.signMessage(Self.message, subaddress: address) }
        // A bad message is reported first.
        assertRefused(.invalidMessage) { try core.signMessage("héllo", subaddress: address) }
    }

    /// The public call on a kit that never started. No wallet2 wallet opens.
    func testKitThatIsNotRunningRefuses() throws {
        let walletId = "sign-message-test-\(UUID().uuidString)"
        defer { try? FileHandler.remove(for: "MoneroKit/\(walletId)") }
        let kit = try Kit(
            wallet: .watch(address: "", viewKey: ""),
            account: 0,
            walletId: walletId,
            node: Node(url: URL(string: "http://localhost:1")!, isTrusted: false),
            reachabilityManager: ReachabilityManager(),
            logger: nil
        )

        assertRefused(.walletNotOpen) { try kit.signMessage(Self.message, subaddress: Self.ownerSubaddress) }
        assertRefused(.invalidMessage) { try kit.signMessage("héllo", subaddress: Self.ownerSubaddress) }
    }
}
