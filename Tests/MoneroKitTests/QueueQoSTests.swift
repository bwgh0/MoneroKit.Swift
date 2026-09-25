import HsToolKit
import XCTest
@testable import MoneroKit

/// Pins the QoS of the two queues a user waits on after unlocking a wallet.
/// At `.background` the wallet open and wallet2's daemon init, which
/// generates an RSA key for its TLS context, starved on a busy CPU: a
/// freshly created wallet sat on "Connecting" with no address for a minute
/// or more (2026-09-25).
final class QueueQoSTests: XCTestCase {

    func testLifecycleQueueIsUserInitiated() throws {
        let walletId = "queue-qos-test-\(UUID().uuidString)"
        defer { try? FileHandler.remove(for: "MoneroKit/\(walletId)") }

        // No network and no wallet2 open happen before `start()`.
        let kit = try Kit(
            wallet: .watch(address: "", viewKey: ""),
            account: 0,
            walletId: walletId,
            node: Node(url: URL(string: "https://node.monero.one:443")!, isTrusted: false),
            reachabilityManager: ReachabilityManager(),
            logger: nil
        )

        let queue = try XCTUnwrap(Mirror(reflecting: kit).descendant("lifecycleQueue") as? DispatchQueue)
        XCTAssertEqual(queue.qos.qosClass, .userInitiated)
    }

    func testSyncPollQueueIsUtility() throws {
        let manager = SyncStateManager(logger: nil, restoreHeight: 0, reachabilityManager: ReachabilityManager())

        let queue = try XCTUnwrap(Mirror(reflecting: manager).descendant("workerQueue") as? DispatchQueue)
        XCTAssertEqual(queue.qos.qosClass, .utility)
    }
}
