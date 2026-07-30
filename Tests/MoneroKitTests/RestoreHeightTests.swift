import XCTest
import MoneroKit

/// Behavioral tests for the date → restore-height estimator.
///
/// The estimator must always land AT or BELOW the true height for the
/// requested date — an overshoot makes a restored wallet skip real
/// transactions. Anchors referenced here are the table entries inside
/// RestoreHeight.swift (last one: 2025-09-01 → 3,490,175); dates past the
/// table extrapolate at 720 blocks/day.
final class RestoreHeightTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testPreLaunchDatesReturnZero() {
        XCTAssertEqual(RestoreHeight.getHeight(date: date(2013, 6, 1)), 0)
        XCTAssertEqual(RestoreHeight.getHeight(date: date(2014, 3, 1)), 0)
    }

    func testMonotonicNonDecreasing() {
        var previous: Int64 = -1
        for year in 2015...2026 {
            for month in stride(from: 1, through: 11, by: 2) {
                let height = RestoreHeight.getHeight(date: date(year, month, 15))
                XCTAssertGreaterThanOrEqual(
                    height, previous,
                    "Height went backwards at \(year)-\(month)"
                )
                previous = height
            }
        }
    }

    func testWithinTableInterpolationStaysBetweenAnchors() {
        // 2023-04-15 (minus the 2-day leeway) sits between the
        // 2023-04-01 (2,854,365) and 2023-05-01 (2,875,972) anchors.
        let height = RestoreHeight.getHeight(date: date(2023, 4, 15))
        XCTAssertGreaterThanOrEqual(height, 2_854_365)
        XCTAssertLessThanOrEqual(height, 2_875_972)
    }

    /// The Julian regression surface: a wallet birthday of May 10 2026 must
    /// estimate past the last table anchor, not clamp to it. (The clamp the
    /// user actually saw came from wallet2 dropping the height — fixed in
    /// monero_c_build — but this guards the Swift half of the chain.)
    func testExtrapolationBeyondTableEnd() {
        let lastAnchor: Int64 = 3_490_175 // 2025-09-01
        let height = RestoreHeight.getHeight(date: date(2026, 5, 10))
        // ~251 days past the anchor at 720 blocks/day ≈ +180k. Bound it
        // loosely: must clearly exceed the anchor, must not overshoot past
        // ~280 days' worth of blocks.
        XCTAssertGreaterThan(height, lastAnchor + 200 * 720)
        XCTAssertLessThan(height, lastAnchor + 280 * 720)
    }

    func testTodayEstimateIsBoundedByMaximum() {
        let today = RestoreHeight.getHeight(date: Date())
        XCTAssertGreaterThan(today, 3_490_175, "Today is past the last table anchor")
        XCTAssertGreaterThanOrEqual(RestoreHeight.maximumEstimatedHeight(), today)
    }
}
