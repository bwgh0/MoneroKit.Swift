import CMonero
import HsToolKit
import XCTest
@testable import MoneroKit

/// The username flow's subaddress calls against real wallet2 objects with no
/// daemon (the node URL points at a closed local port). The wallets are
/// throwaway wallets in this test's temporary folder, made from a public
/// BIP39 test seed. Never send funds to their addresses.
///
/// A "quit" is a copy of the wallet files while the wallet is still open:
/// the copy holds what wallet2 has written so far, as the files of an app
/// that iOS stopped at that moment.
final class SubaddressStoreTests: XCTestCase {
    /// The BIP39 vector of WalletCreationIntegrationTests.
    private static let seed = Array(repeating: "abandon", count: 23) + ["art"]

    private var tempDir: URL!
    private var cores: [MoneroCore] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubaddressStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for core in cores {
            core.stop()
        }
        cores = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openWallet(name: String) throws -> MoneroCore {
        let core = MoneroCore(
            wallet: .bip39(seed: Self.seed, passphrase: ""),
            account: 0,
            walletPath: tempDir.appendingPathComponent(name).path,
            walletPassword: "pw",
            // Nothing listens on port 1, so no daemon call can succeed.
            node: Node(url: URL(string: "http://localhost:1")!, isTrusted: false),
            restoreHeight: 0,
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: nil
        )
        cores.append(core)
        core.prepare()
        XCTAssertNotNil(core.getWalletPointer(), "\(name): wallet did not open")
        return core
    }

    /// Copies the files of wallet `name` (`name`, `name.keys`, ...) to
    /// wallet `copy`, as they are on disk now.
    private func copyFiles(of name: String, to copy: String) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        for file in files where file == name || file.hasPrefix(name + ".") {
            try FileManager.default.copyItem(
                at: tempDir.appendingPathComponent(file),
                to: tempDir.appendingPathComponent(copy + file.dropFirst(name.count)))
        }
        XCTAssertTrue(files.contains(name + ".keys"), "no keys file for \(name)")
    }

    private func address(_ core: MoneroCore, _ index: Int) throws -> String {
        let wallet = try XCTUnwrap(core.getWalletPointer())
        return try XCTUnwrap(stringFromCString(MONERO_Wallet_address(wallet, 0, UInt64(index))))
    }

    // MARK: - B1: a new subaddress survives a quit

    func testStoredSubaddressSurvivesAQuitAndAPlainOneDoesNot() throws {
        let core = try openWallet(name: "owner")
        XCTAssertEqual(core.subaddressCount(), 1, "a new wallet lists its primary address only")

        // The plain add keeps the row in memory: a quit forgets it.
        let plain = try XCTUnwrap(core.addSubaddress(label: "plain"))
        XCTAssertEqual(plain.index, 1)
        XCTAssertEqual(core.subaddressCount(), 2)
        try copyFiles(of: "owner", to: "quitAfterPlain")

        // The username flow's add writes the wallet file before it returns.
        let stored = try core.addSubaddressAndStore(label: "")
        XCTAssertEqual(stored.index, 2)
        XCTAssertEqual(stored.address, try address(core, 2))
        XCTAssertEqual(core.subaddressCount(), 3)
        try copyFiles(of: "owner", to: "quitAfterStore")

        let afterPlain = try openWallet(name: "quitAfterPlain")
        XCTAssertEqual(afterPlain.subaddressCount(), 1, "the plain add was not on disk yet (the old flow)")

        let afterStore = try openWallet(name: "quitAfterStore")
        XCTAssertEqual(afterStore.subaddressCount(), 3)
        XCTAssertEqual(try address(afterStore, 2), stored.address)
        XCTAssertEqual(afterStore.getSubaddressLabel(index: 1), "plain")
        // The next new subaddress gets a new index, not the claimed one.
        let next = try afterStore.addSubaddressAndStore(label: "")
        XCTAssertEqual(next.index, 3)
        XCTAssertNotEqual(next.address, stored.address)
    }

    // MARK: - B2: a restored wallet finds and lists its own subaddress

    func testFindsAndListsASubaddressTheWalletDoesNotList() throws {
        let core = try openWallet(name: "owner")
        let seventh = try address(core, 7)
        XCTAssertEqual(core.subaddressCount(), 1)

        XCTAssertEqual(core.subaddressIndex(of: seventh, below: core.subaddressCount() + 1000), 7)
        // The scan stops below its limit, and never returns the primary address.
        XCTAssertNil(core.subaddressIndex(of: seventh, below: 7))
        XCTAssertNil(core.subaddressIndex(of: try address(core, 0), below: 1000))

        XCTAssertTrue(try core.listSubaddressAndStore(index: 7, address: seventh))
        XCTAssertEqual(core.subaddressCount(), 8)
        XCTAssertEqual(core.getSubaddressLabel(index: 3), "", "the rows before it get no label")

        // A row that is already listed: no new rows.
        XCTAssertTrue(try core.listSubaddressAndStore(index: 3, address: try address(core, 3)))
        XCTAssertEqual(core.subaddressCount(), 8)

        // The rows are on disk.
        try copyFiles(of: "owner", to: "quit")
        let copy = try openWallet(name: "quit")
        XCTAssertEqual(copy.subaddressCount(), 8)
        XCTAssertEqual(try address(copy, 7), seventh)
    }

    func testAnAddressAtAnotherIndexListsNothing() throws {
        let core = try openWallet(name: "owner")
        let seventh = try address(core, 7)

        XCTAssertFalse(try core.listSubaddressAndStore(index: 5, address: seventh))
        XCTAssertFalse(try core.listSubaddressAndStore(index: 0, address: try address(core, 0)))
        XCTAssertFalse(try core.listSubaddressAndStore(index: 7, address: seventh + "0"))
        XCTAssertEqual(core.subaddressCount(), 1)
    }

    /// The scan of a name's owner that is not this wallet's: the full range.
    /// It runs on the kit's lifecycle queue, never on the main thread.
    func testScanOfAForeignAddressEndsAtItsLimit() throws {
        let core = try openWallet(name: "owner")
        let foreign = try address(core, 2000)
        let start = Date()
        XCTAssertNil(core.subaddressIndex(of: foreign, below: core.subaddressCount() + Kit.subaddressSearchRange))
        print("SUBADDRESS_SCAN range=\(Kit.subaddressSearchRange) seconds=\(Date().timeIntervalSince(start))")
    }
}
