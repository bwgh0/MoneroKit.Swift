import XCTest
@testable import MoneroKit

/// The node sends the daemon height and each block's timestamp, so a bad
/// node can send any 64-bit value. Before the fix, a value above Int.max
/// trapped in the kit's `Int` conversions (the sync progress, the stored
/// heights and the transaction timestamp), and the app crashed for every
/// wallet on that node.
final class NodeValueOverflowTests: XCTestCase {

    func testRealDaemonHeightsPassUnchanged() {
        XCTAssertEqual(SyncStateManager.usableDaemonHeight(0), 0)
        XCTAssertEqual(SyncStateManager.usableDaemonHeight(3_500_000), 3_500_000)
        XCTAssertEqual(SyncStateManager.usableDaemonHeight(SyncStateManager.maxBlockHeight), SyncStateManager.maxBlockHeight)
    }

    func testImpossibleDaemonHeightCountsAsNoHeight() {
        XCTAssertEqual(SyncStateManager.usableDaemonHeight(SyncStateManager.maxBlockHeight + 1), 0)
        XCTAssertEqual(SyncStateManager.usableDaemonHeight(UInt64(Int64.max) + 1), 0)
        XCTAssertEqual(SyncStateManager.usableDaemonHeight(UInt64.max), 0)
    }

    /// In range, the result matches `Int(_:)`, which truncates.
    func testRealTimestampsMatchIntConversion() {
        XCTAssertEqual(Transaction.unixTime(Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(Transaction.unixTime(Date(timeIntervalSince1970: 1_506_000_000)), 1_506_000_000)
        XCTAssertEqual(Transaction.unixTime(Date(timeIntervalSince1970: 1_760_659_200.75)), 1_760_659_200)
    }

    /// MoneroCore makes the date from the node's UInt64 timestamp, as here.
    func testTimestampAboveIntMaxIsClamped() {
        XCTAssertEqual(Transaction.unixTime(Date(timeIntervalSince1970: TimeInterval(UInt64.max))), Int.max)
        XCTAssertEqual(Transaction.unixTime(Date(timeIntervalSince1970: 1e19)), Int.max)
    }
}
