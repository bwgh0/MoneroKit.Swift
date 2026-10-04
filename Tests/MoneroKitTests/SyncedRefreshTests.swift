import HsToolKit
import XCTest
@testable import MoneroKit

/// A synced wallet that stays open must keep publishing new blocks. Before
/// this fix the first `.synced` report stopped the state poll with `stop()`,
/// which paused wallet2's refresh and cleared the state callback: heights,
/// confirmations and history froze until the app relaunched (2026-10-03).
final class SyncedRefreshTests: XCTestCase {

    func testSyncedAtNewHeightIsReportedAgain() {
        XCTAssertTrue(SyncStateManager.reportsSyncedAgain(current: .synced, new: .synced, walletHeight: 101, reportedSyncedHeight: 100))
    }

    func testSyncedAtSameHeightIsNotReportedAgain() {
        XCTAssertFalse(SyncStateManager.reportsSyncedAgain(current: .synced, new: .synced, walletHeight: 100, reportedSyncedHeight: 100))
    }

    func testFirstSyncedCheckAfterRestartIsReported() {
        XCTAssertTrue(SyncStateManager.reportsSyncedAgain(current: .synced, new: .synced, walletHeight: 100, reportedSyncedHeight: nil))
    }

    /// A change of state reaches the callback through `state`'s didSet.
    func testStateChangesAreLeftToDidSet() {
        XCTAssertFalse(SyncStateManager.reportsSyncedAgain(current: .syncing(progress: 99, remainingBlocksCount: 1), new: .synced, walletHeight: 101, reportedSyncedHeight: 100))
        XCTAssertFalse(SyncStateManager.reportsSyncedAgain(current: .synced, new: .syncing(progress: 99, remainingBlocksCount: 1), walletHeight: 100, reportedSyncedHeight: 100))
    }

    /// The synced path must keep the callback; only teardown clears it.
    func testStopPollingKeepsStateCallback() {
        let manager = SyncStateManager(logger: nil, restoreHeight: 0, reachabilityManager: ReachabilityManager())
        manager.onSyncStateChanged = {}

        manager.stopPolling()
        XCTAssertNotNil(manager.onSyncStateChanged)

        manager.stop()
        XCTAssertNil(manager.onSyncStateChanged)
    }
}
