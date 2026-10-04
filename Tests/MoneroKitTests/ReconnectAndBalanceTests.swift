import HsToolKit
import XCTest
@testable import MoneroKit

/// Two faults of an open wallet, both checked against a real wallet2 object
/// with no daemon (the node URL points at a closed local port):
///
/// - A lost network stopped the wallet services for good. The stop cleared
///   the state callback, so the reachability event of the returning network
///   never reached `MoneroCore` and the wallet never synced again.
/// - The first balance read after a wallet opened did not publish when it
///   equaled the in-memory default of 0. The app kept the stored balance of
///   the last run, for example after the wallet was emptied on another device.
final class ReconnectAndBalanceTests: XCTestCase {

    private var tempDir: URL!
    private var core: MoneroCore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconnectAndBalanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        core = MoneroCore(
            wallet: .bip39(seed: Array(repeating: "abandon", count: 23) + ["art"], passphrase: ""),
            account: 0,
            walletPath: tempDir.appendingPathComponent("wallet").path,
            walletPassword: "pw",
            // Nothing listens on port 1, so every daemon call fails at once.
            node: Node(url: URL(string: "http://localhost:1")!, isTrusted: false),
            restoreHeight: 0,
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: nil
        )
    }

    override func tearDownWithError() throws {
        core?.stop()
        core = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func stateManager() throws -> SyncStateManager {
        try XCTUnwrap(Mirror(reflecting: core!).descendant("stateManager") as? SyncStateManager)
    }

    private func walletListener() throws -> WalletListener {
        try XCTUnwrap(Mirror(reflecting: core!).descendant("walletListener") as? WalletListener)
    }

    private func isRunning(_ object: Any) -> Bool? {
        Mirror(reflecting: object).descendant("isRunning") as? Bool
    }

    /// Sends a reachability change the way `SyncStateManager`'s
    /// `$isReachable` sink does: it sets `state` on the state queue.
    private func reachabilityChanged(_ isReachable: Bool, _ manager: SyncStateManager) {
        manager.queue.sync {
            manager.state = .idle(daemonReachable: isReachable)
        }
    }

    // MARK: - Network drop

    func testReturningNetworkRestartsWalletServices() throws {
        core.start()
        XCTAssertNotNil(core.getWalletPointer(), "wallet did not open")

        let manager = try stateManager()
        let listener = try walletListener()
        XCTAssertEqual(isRunning(manager), true)
        XCTAssertEqual(isRunning(listener), true)

        reachabilityChanged(false, manager)
        XCTAssertEqual(manager.state, .idle(daemonReachable: false))
        XCTAssertEqual(isRunning(manager), false, "services still run without a network")
        XCTAssertEqual(isRunning(listener), false, "services still run without a network")

        reachabilityChanged(true, manager)
        XCTAssertEqual(manager.state, .connecting(waiting: false), "returning network did not restart the wallet services")
        XCTAssertEqual(isRunning(manager), true, "state poll did not restart")
        XCTAssertEqual(isRunning(listener), true, "wallet listener did not restart")

        // A synced wallet relies on these to publish new blocks
        // (SyncedRefreshTests).
        XCTAssertNotNil(manager.onSyncStateChanged)
        XCTAssertNotNil(listener.onNewBlock)
        XCTAssertNotNil(listener.onNewTransaction)
    }

    /// The restart after a network drop must not bring back callbacks
    /// against a closed wallet: `stop()` clears them for good.
    func testStopClearsCallbacksForGood() throws {
        core.start()
        let manager = try stateManager()
        let listener = try walletListener()

        reachabilityChanged(false, manager)
        core.stop()
        XCTAssertNil(core.getWalletPointer())
        XCTAssertNil(manager.onSyncStateChanged)
        XCTAssertNil(listener.onNewBlock)
        XCTAssertNil(listener.onNewTransaction)

        reachabilityChanged(true, manager)
        XCTAssertEqual(manager.state, .idle(daemonReachable: true))
        XCTAssertEqual(isRunning(manager), false)
        XCTAssertEqual(isRunning(listener), false)
    }

    // MARK: - First balance

    func testFirstBalanceReadPublishesZero() throws {
        let spy = DelegateSpy()
        core.delegate = spy
        core.prepare()
        XCTAssertNotNil(core.getWalletPointer(), "wallet did not open")

        let published = expectation(description: "first balance read is published")
        spy.onBalance = { balance in
            XCTAssertEqual(balance, MoneroCore.Balance(all: 0, unlocked: 0))
            published.fulfill()
        }
        core.refresh()
        wait(for: [published], timeout: 5)

        // An unchanged balance still publishes nothing.
        let republished = expectation(description: "unchanged balance is not published again")
        republished.isInverted = true
        spy.onBalance = { _ in republished.fulfill() }
        core.refresh()
        wait(for: [republished], timeout: 1)
    }
}

private final class DelegateSpy: MoneroCoreDelegate {
    var onBalance: ((MoneroCore.Balance) -> Void)?

    func balanceDidChange(balance: MoneroCore.Balance) { onBalance?(balance) }
    func transactionsDidChange(transactions: [MoneroCore.Transaction]) {}
    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress]) {}
    func walletStateDidChange(state: WalletState) {}
    func restoreHeightUpdated(height: UInt64) {}
}
