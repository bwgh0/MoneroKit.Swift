import XCTest
@testable import MoneroKit

/// The fallback `getHeight` uses when the table lookup fails. A restore
/// height later than the true one hides funds, so the fallback must never
/// pass the true height. A new wallet must never get 0 (a scan from block 0).
final class RestoreHeightFallbackTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testFallbackIsTheNewestAnchorOnOrBeforeTheDate() {
        XCTAssertEqual(RestoreHeight.anchorHeight(atOrBefore: date(2022, 6, 10)), 2_635_840)
        XCTAssertEqual(RestoreHeight.anchorHeight(atOrBefore: date(2022, 6, 1, hour: 0)), 2_635_840)
        XCTAssertEqual(RestoreHeight.anchorHeight(atOrBefore: date(2022, 5, 31, hour: 23, minute: 59)), 2_613_603)
    }

    func testFallbackBeforeTheFirstAnchorIsZero() {
        XCTAssertEqual(RestoreHeight.anchorHeight(atOrBefore: date(2013, 6, 1)), 0)
        XCTAssertEqual(RestoreHeight.anchorHeight(atOrBefore: date(2014, 4, 30)), 0)
    }

    func testFallbackForANewWalletIsNeverZero() {
        XCTAssertGreaterThanOrEqual(RestoreHeight.anchorHeight(atOrBefore: Date()), 3_490_175)
    }

    /// The lookup keeps a 2-day margin, so from the 3rd of a month on the
    /// fallback must not be above it.
    func testFallbackIsNeverAboveTheTableLookup() {
        for year in 2014...2026 {
            for month in 1...12 {
                for day in [3, 10, 20, 28] {
                    let query = date(year, month, day)
                    guard query <= Date() else { continue }
                    XCTAssertLessThanOrEqual(
                        RestoreHeight.anchorHeight(atOrBefore: query),
                        RestoreHeight.getHeight(date: query),
                        "\(year)-\(month)-\(day)"
                    )
                }
            }
        }
    }
}
