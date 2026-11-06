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

    /// Runs `work` on another thread. Its result, or nil while it still
    /// runs after `timeout`.
    private final class Running<Value> {
        private let done = DispatchSemaphore(value: 0)
        private var result: Result<Value, Error>?

        init(_ work: @escaping () throws -> Value) {
            DispatchQueue.global().async { [self] in
                result = Result { try work() }
                done.signal()
            }
        }

        func wait(_ timeout: TimeInterval) -> Result<Value, Error>? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            done.signal()
            return result
        }
    }

    /// I4 (overlap): the add waits for a refresh pass in flight, whose
    /// threads read and grow wallet2's subaddress table with no lock. The
    /// store after it finds the refresh at rest and lands before the return.
    func testNewSubaddressWaitsForARefreshPassInFlightAndStoresAtOnce() throws {
        let node = try SilentNode()
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        _ = try startRefreshAtSilentNode(core, node)

        let add = Running { try core.addSubaddressAndStore(label: "", addWait: 30) }
        XCTAssertNil(add.wait(1.5), "the add ran while the refresh pass was in flight")
        try copyFiles(of: "owner", to: "quitDuringPass")

        node.close()
        let created = try XCTUnwrap(add.wait(15), "the add did not run after the pass").get()
        XCTAssertEqual(created.index, 1)
        XCTAssertEqual(created.address, try address(core, 1))
        try copyFiles(of: "owner", to: "quitAfterAdd")

        XCTAssertEqual(try openWallet(name: "quitDuringPass").subaddressCount(), 1)
        let afterAdd = try openWallet(name: "quitAfterAdd")
        XCTAssertEqual(afterAdd.subaddressCount(), 2, "the add returned before its store")
        XCTAssertEqual(try address(afterAdd, 1), created.address)
    }

    /// I4 (rename): the label waits off the caller's thread for the slow
    /// refresh, then lands in the wallet file.
    func testRenameStoresAfterASlowRefresh() throws {
        let node = try SilentNode()
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        XCTAssertEqual(try core.addSubaddressAndStore(label: "old").index, 1)
        _ = try startRefreshAtSilentNode(core, node)

        let rename = Running { try core.setSubaddressLabelAndStore(index: 1, label: "Rent", labelWait: 30) }
        XCTAssertNil(rename.wait(1.5), "the label changed while the refresh pass was in flight")

        node.close()
        XCTAssertNoThrow(try XCTUnwrap(rename.wait(15), "the rename did not run after the pass").get())
        XCTAssertEqual(core.getSubaddressLabel(index: 1), "Rent")
        try copyFiles(of: "owner", to: "quit")
        XCTAssertEqual(try openWallet(name: "quit").getSubaddressLabel(index: 1), "Rent", "the label is not in the wallet file")
    }

    /// A change that cannot start within its wait fails at once and changes
    /// nothing, also later.
    func testAChangeThatCannotStartInTimeChangesNothing() throws {
        let node = try SilentNode()
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        XCTAssertEqual(try core.addSubaddressAndStore(label: "old").index, 1)
        _ = try startRefreshAtSilentNode(core, node)

        let start = Date()
        func assertBusy(_ error: Error) {
            guard case let MoneroCoreError.walletStatusError(message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(message, "The wallet is busy")
        }
        XCTAssertThrowsError(try core.addSubaddressAndStore(label: "", addWait: 0.5), "", assertBusy)
        XCTAssertThrowsError(try core.setSubaddressLabelAndStore(index: 1, label: "new", labelWait: 0.5), "", assertBusy)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)

        node.close()
        core.waitForSubaddressStores()
        XCTAssertEqual(core.subaddressCount(), 2, "the abandoned add added a row")
        XCTAssertEqual(core.getSubaddressLabel(index: 1), "old", "the abandoned rename changed the label")
        XCTAssertEqual(try core.addSubaddressAndStore(label: "").index, 2)
    }

    // MARK: - I4: no refresh while sync is paused

    /// Connects `core` to `node` (no daemon call: see
    /// `startRefreshAtSilentNode`). A refresh that runs then calls the node
    /// every 0.2 s, so a refresh left on shows at once.
    private func connect(_ core: MoneroCore) throws {
        let wallet = try XCTUnwrap(core.getWalletPointer())
        MONERO_Wallet_setRecoveringFromSeed(wallet, true)
        let connected = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            core.connectToDaemon()
            connected.signal()
        }
        XCTAssertEqual(connected.wait(timeout: .now() + 15), .success, "wallet2's init waited for the node")
        MONERO_Wallet_setAutoRefreshInterval(wallet, 200)
    }

    /// Trusted Locations pause sync outside a trusted place: then the app
    /// must not call the node. A new address and a rename are stored, and
    /// the refresh runs only when sync resumes.
    func testANewAddressAndARenameWhileSyncIsPausedNeverStartTheRefresh() throws {
        let node = try CountingNode(holding: false)
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        try connect(core)
        core.startSync()
        XCTAssertTrue(node.waitForConnections(moreThan: 0, timeout: 15), "the refresh did not reach the node")

        core.pauseSync()
        let paused = node.settledConnections()

        let created = try core.addSubaddressAndStore(label: "")
        XCTAssertEqual(created.index, 1)
        try core.setSubaddressLabelAndStore(index: 1, label: "Rent")
        XCTAssertEqual(try core.listSubaddressAndStore(index: 3, address: try address(core, 3)), true)
        XCTAssertFalse(node.waitForConnections(moreThan: paused, timeout: 2),
                       "a subaddress change started the refresh while sync was paused")
        XCTAssertFalse(core.refreshGate.isSyncOn)

        try copyFiles(of: "owner", to: "quit")
        let copy = try openWallet(name: "quit")
        XCTAssertEqual(copy.subaddressCount(), 4)
        XCTAssertEqual(copy.getSubaddressLabel(index: 1), "Rent")

        core.startSync()
        XCTAssertTrue(node.waitForConnections(moreThan: paused, timeout: 15), "the refresh did not run when sync resumed")
    }

    /// The network goes down and comes back while sync is paused: the
    /// wallet services start only when sync resumes.
    func testTheNetworkComingBackWhileSyncIsPausedDoesNotStartTheRefresh() throws {
        let node = try CountingNode(holding: false)
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        try connect(core)
        core.startSync()
        XCTAssertTrue(node.waitForConnections(moreThan: 0, timeout: 15), "the refresh did not reach the node")

        core.pauseSync()
        let paused = node.settledConnections()

        core.stateManager.state = .idle(daemonReachable: false)
        core.stateManager.state = .idle(daemonReachable: true)
        XCTAssertFalse(node.waitForConnections(moreThan: paused, timeout: 2),
                       "the network's return started the refresh while sync was paused")
        XCTAssertFalse(core.refreshGate.isSyncOn)

        core.startSync()
        XCTAssertTrue(core.refreshGate.isSyncOn)
        XCTAssertTrue(node.waitForConnections(moreThan: paused, timeout: 15), "the refresh did not run when sync resumed")
    }

    /// A sync store that waits for a refresh pass across `pauseSync` ends
    /// with the refresh off. Its LOCK_REFRESH read the refresh as on when it
    /// began, and started it again when it ended.
    func testAStoreThatWaitsAcrossThePauseDoesNotStartTheRefreshAgain() throws {
        let node = try CountingNode(holding: true)
        defer { node.close() }
        let core = try openWallet(name: "owner", nodeURL: node.url)
        try connect(core)
        let wallet = try XCTUnwrap(core.getWalletPointer())
        // Sync on, without the state manager's polls.
        core.refreshGate.syncStarted(wallet)
        XCTAssertTrue(node.waitForConnections(moreThan: 0, timeout: 15), "the refresh did not reach the node")

        let store = Running { core.refresh() }
        XCTAssertNil(store.wait(1), "the store did not wait for the refresh pass")
        core.pauseSync()
        XCTAssertFalse(core.refreshGate.isSyncOn)

        node.stopHolding()
        XCTAssertNotNil(store.wait(15), "the store did not end after the pass")
        let paused = node.settledConnections()
        XCTAssertFalse(node.waitForConnections(moreThan: paused, timeout: 2),
                       "the store started the refresh again after the pause")
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

/// A node that takes each TCP connection and counts it: each one is a call
/// to the node. While it holds them, it never answers, as a dead node, and a
/// refresh that reaches it waits in wallet2's daemon call. Else it closes
/// each connection at once, and the call fails at once. It listens on
/// "localhost" at a free port.
private final class CountingNode {
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var holding: Bool
    private var held: [Int32] = []
    private var count = 0
    private var stopped = false
    private let acceptEnded = DispatchSemaphore(value: 0)

    init(holding: Bool) throws {
        self.holding = holding
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", "0", &hints, &info) == 0, let first = info else {
            throw SilentNode.SetupError(step: "getaddrinfo")
        }
        defer { freeaddrinfo(info) }
        socketFD = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard socketFD >= 0 else { throw SilentNode.SetupError(step: "socket") }
        guard bind(socketFD, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            throw SilentNode.SetupError(step: "bind")
        }
        guard listen(socketFD, 8) == 0 else { throw SilentNode.SetupError(step: "listen") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { throw SilentNode.SetupError(step: "getsockname") }
        port = UInt16(bigEndian: bound.sin_port)
        let listening = socketFD
        Thread.detachNewThread { [self] in acceptLoop(listening) }
    }

    var url: URL { URL(string: "http://localhost:\(port)")! }

    var connections: Int { lock.withLock { count } }

    private func acceptLoop(_ listening: Int32) {
        defer { acceptEnded.signal() }
        while !lock.withLock({ stopped }) {
            var entry = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, 50) > 0 else { continue }
            let connection = accept(listening, nil, nil)
            guard connection >= 0 else { continue }
            let keep: Bool = lock.withLock {
                count += 1
                if holding { held.append(connection) }
                return holding
            }
            if !keep { Darwin.close(connection) }
        }
    }

    /// True once more than `count` connections came within `timeout`.
    func waitForConnections(moreThan count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connections > count { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return connections > count
    }

    /// The count once no connection came for a second: a pass in flight has
    /// ended.
    func settledConnections() -> Int {
        var last = connections
        for _ in 0 ..< 20 {
            Thread.sleep(forTimeInterval: 1)
            let now = connections
            if now == last { return now }
            last = now
        }
        return last
    }

    /// Closes the held connections, and closes each later one at once.
    func stopHolding() {
        let open: [Int32] = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        open.forEach { Darwin.close($0) }
    }

    func close() {
        let first: Bool = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        acceptEnded.wait()
        stopHolding()
        Darwin.close(socketFD)
        socketFD = -1
    }

    deinit { close() }
}
