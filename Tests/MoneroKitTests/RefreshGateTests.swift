import XCTest
@testable import MoneroKit

/// `RefreshGate` alone: who may start wallet2's refresh thread.
final class RefreshGateTests: XCTestCase {
    private let wallet = UnsafeMutableRawPointer(bitPattern: 0x1)!
    private var events: [String] = []

    private func makeGate() -> RefreshGate {
        RefreshGate(
            startRefresh: { [unowned self] _ in events.append("start") },
            pauseRefresh: { [unowned self] _ in events.append("pause") }
        )
    }

    func testAHoldWhileSyncIsPausedNeverStartsTheRefresh() {
        let gate = makeGate()
        gate.syncStarted(wallet)
        gate.syncPaused(wallet)
        events = []

        gate.hold(wallet)
        gate.release(wallet)
        XCTAssertEqual(events, ["pause"])
        XCTAssertFalse(gate.isSyncOn)

        gate.syncStarted(wallet)
        XCTAssertEqual(events, ["pause", "start"])
    }

    func testAHoldWhileSyncIsOnStartsTheRefreshAgainAtItsRelease() {
        let gate = makeGate()
        gate.syncStarted(wallet)
        events = []

        gate.hold(wallet)
        gate.release(wallet)
        XCTAssertEqual(events, ["pause", "start"])
    }

    func testSyncStartedDuringHoldsStartsTheRefreshAtTheLastRelease() {
        let gate = makeGate()
        gate.hold(wallet)
        gate.hold(wallet)
        gate.syncStarted(wallet)
        XCTAssertEqual(events, ["pause", "pause"], "the refresh started during a hold")

        gate.release(wallet)
        XCTAssertEqual(events, ["pause", "pause"], "the refresh started before the last release")
        gate.release(wallet)
        XCTAssertEqual(events, ["pause", "pause", "start"])
    }

    func testAPauseDuringAHoldIsNotUndoneByItsRelease() {
        let gate = makeGate()
        gate.syncStarted(wallet)
        gate.hold(wallet)
        gate.syncPaused(wallet)
        events = []

        gate.release(wallet)
        XCTAssertEqual(events, [], "the release started the refresh after the pause")
    }
}
