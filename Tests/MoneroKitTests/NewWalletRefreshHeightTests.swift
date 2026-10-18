import XCTest
@testable import MoneroKit

/// wallet2 moves the refresh height of a wallet with no synced blocks to
/// the daemon tip on init. A restored wallet killed before its first sync
/// then skipped its whole history. The kit puts the saved height back.
final class NewWalletRefreshHeightTests: XCTestCase {
    func testAWalletWithNoSyncedBlocksGetsItsRestoreHeightBack() {
        // Init moved it to the tip.
        XCTAssertEqual(MoneroCore.refreshHeightAfterInit(blockChainHeight: 1, refreshHeight: 3_500_000, restoreHeight: 3_100_000), 3_100_000)
        XCTAssertEqual(MoneroCore.refreshHeightAfterInit(blockChainHeight: 0, refreshHeight: 3_500_000, restoreHeight: 3_100_000), 3_100_000)
        // A full scan stays a full scan.
        XCTAssertEqual(MoneroCore.refreshHeightAfterInit(blockChainHeight: 1, refreshHeight: 3_500_000, restoreHeight: 0), 0)
    }

    func testASyncedOrUntouchedWalletKeepsItsHeight() {
        // Init left it alone.
        XCTAssertNil(MoneroCore.refreshHeightAfterInit(blockChainHeight: 1, refreshHeight: 3_100_000, restoreHeight: 3_100_000))
        // The cache has synced blocks: wallet2 never moves it.
        XCTAssertNil(MoneroCore.refreshHeightAfterInit(blockChainHeight: 3_200_000, refreshHeight: 3_100_000, restoreHeight: 3_000_000))
        XCTAssertNil(MoneroCore.refreshHeightAfterInit(blockChainHeight: 2, refreshHeight: 3_500_000, restoreHeight: 3_100_000))
    }
}
