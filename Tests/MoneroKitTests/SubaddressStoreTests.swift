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

    /// - Parameter nodeURL: by default port 1, where nothing listens, so no
    ///   daemon call can succeed.
    private func openWallet(name: String, nodeURL: URL = URL(string: "http://localhost:1")!) throws -> MoneroCore {
        let core = MoneroCore(
            wallet: .bip39(seed: Self.seed, passphrase: ""),
            account: 0,
            walletPath: tempDir.appendingPathComponent(name).path,
            walletPassword: "pw",
            node: Node(url: nodeURL, isTrusted: false),
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

    // MARK: - I3: the store does not hold the caller while a refresh waits for a dead node

    /// Connects `core` to `node` and starts wallet2's refresh. Returns when
    /// the refresh waits at the node: `doRefresh` is in its daemon call and
    /// holds both refresh mutexes.
    private func startRefreshAtSilentNode(_ core: MoneroCore, _ node: SilentNode) throws -> UnsafeMutableRawPointer {
        let wallet = try XCTUnwrap(core.getWalletPointer())
        // wallet2's init asks the daemon for its height when it takes the
        // wallet for a new one. A restored wallet skips that call.
        MONERO_Wallet_setRecoveringFromSeed(wallet, true)
        let connected = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            core.connectToDaemon()
            connected.signal()
        }
        guard connected.wait(timeout: .now() + 10) == .success else {
            node.close()
            _ = connected.wait(timeout: .now() + 30)
            throw SilentNode.SetupError(step: "wallet2's init called the node")
        }
        MONERO_Wallet_startRefresh(wallet)
        guard node.waitForConnection(timeout: 15) else {
            throw SilentNode.SetupError(step: "the refresh did not reach the node")
        }
        return wallet
    }

    /// The cause of the wait: `WalletImpl::store` takes the refresh mutexes
    /// (LOCK_REFRESH), and the refresh holds them while its daemon call
    /// waits for the node.
    func testStoreWaitsForARefreshThatWaitsForTheNode() throws {
        let node = try SilentNode()
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        let wallet = try startRefreshAtSilentNode(core, node)

        let stored = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = MONERO_Wallet_store(wallet, "")
            stored.signal()
        }
        XCTAssertEqual(stored.wait(timeout: .now() + 2), .timedOut, "the store did not wait for the refresh")

        node.close()
        XCTAssertEqual(stored.wait(timeout: .now() + 15), .success, "the store did not end after the refresh")
    }

    /// The fix: New Address gets its row after the add and a short wait. The
    /// store lands when the refresh ends; until then the kit's database
    /// keeps the row (`Kit.relistStoredSubaddresses`).
    func testNewSubaddressReturnsBeforeAStoreThatWaitsForTheRefresh() throws {
        let node = try SilentNode()
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        _ = try startRefreshAtSilentNode(core, node)

        let start = Date()
        let created = try core.addSubaddressAndStore(label: "", storeWait: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the caller waited for the refresh")
        XCTAssertEqual(created.index, 1)
        XCTAssertEqual(created.address, try address(core, 1))
        XCTAssertTrue(core.subaddressStorePending, "the store did not wait for the refresh")
        try copyFiles(of: "owner", to: "quitBeforeStore")

        node.close()
        core.waitForSubaddressStores()
        XCTAssertFalse(core.subaddressStorePending)
        try copyFiles(of: "owner", to: "quitAfterStore")

        XCTAssertEqual(try openWallet(name: "quitBeforeStore").subaddressCount(), 1,
                       "the store landed before the refresh ended")
        let afterStore = try openWallet(name: "quitAfterStore")
        XCTAssertEqual(afterStore.subaddressCount(), 2)
        XCTAssertEqual(try address(afterStore, 1), created.address)
    }

    /// A second New Address while the first store waits: it waits a moment
    /// for the queue, then fails and adds nothing, also later.
    func testASecondNewSubaddressBehindAWaitingStoreAddsNothing() throws {
        let node = try SilentNode()
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        _ = try startRefreshAtSilentNode(core, node)

        XCTAssertEqual(try core.addSubaddressAndStore(label: "", storeWait: 0.2).index, 1)
        let start = Date()
        XCTAssertThrowsError(try core.addSubaddressAndStore(label: "", addWait: 0.5, storeWait: 0.2)) { error in
            guard case let MoneroCoreError.walletStatusError(message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(message, "The wallet is busy")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        node.close()
        core.waitForSubaddressStores()
        XCTAssertEqual(core.subaddressCount(), 2, "the abandoned add added a row")
        XCTAssertEqual(try core.addSubaddressAndStore(label: "").index, 2)
    }

    /// The next open lists again the rows that the database has and the
    /// wallet file lacks: a quit before the store landed.
    func testRelistsTheDatabaseRowsTheWalletFileLacks() throws {
        let core = try openWallet(name: "owner")
        let rows = try (0 ... 2).map { try SubAddress(address: address(core, $0), index: $0) }

        Kit.relistStoredSubaddresses(rows, in: core)
        XCTAssertEqual(core.subaddressCount(), 3)

        try copyFiles(of: "owner", to: "quit")
        let copy = try openWallet(name: "quit")
        XCTAssertEqual(copy.subaddressCount(), 3)
        XCTAssertEqual(try address(copy, 2), rows[2].address)
        XCTAssertEqual(try copy.addSubaddressAndStore(label: "").index, 3, "the next new subaddress reused an index")
    }

    func testRelistIgnoresRowsOfAnotherAddressAndRowsTheFileHas() throws {
        let core = try openWallet(name: "owner")
        Kit.relistStoredSubaddresses([try SubAddress(address: address(core, 5), index: 2)], in: core)
        XCTAssertEqual(core.subaddressCount(), 1)
        Kit.relistStoredSubaddresses([try SubAddress(address: address(core, 0), index: 0)], in: core)
        XCTAssertEqual(core.subaddressCount(), 1)
        Kit.relistStoredSubaddresses([], in: core)
        XCTAssertEqual(core.subaddressCount(), 1)
    }
}

/// A node that takes TCP connections and never answers, as a dead node. A
/// refresh that reaches it waits in wallet2's daemon call until `close()`
/// resets the connection. It listens on "localhost" at a free port.
private final class SilentNode {
    private(set) var port: UInt16 = 0
    private var socketFD: Int32 = -1

    struct SetupError: Error {
        let step: String
    }

    init() throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", "0", &hints, &info) == 0, let first = info else {
            throw SetupError(step: "getaddrinfo")
        }
        defer { freeaddrinfo(info) }
        socketFD = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard socketFD >= 0 else { throw SetupError(step: "socket") }
        guard bind(socketFD, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            throw SetupError(step: "bind")
        }
        guard listen(socketFD, 8) == 0 else { throw SetupError(step: "listen") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { throw SetupError(step: "getsockname") }
        port = UInt16(bigEndian: bound.sin_port)
    }

    var url: URL { URL(string: "http://localhost:\(port)")! }

    /// True once a connection waits to be accepted: a refresh reached the
    /// node.
    func waitForConnection(timeout: TimeInterval) -> Bool {
        var entry = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, Int32(timeout * 1000)) > 0
    }

    /// Resets the waiting connections. Later connects are refused.
    func close() {
        guard socketFD >= 0 else { return }
        Darwin.close(socketFD)
        socketFD = -1
    }

    deinit { close() }
}
