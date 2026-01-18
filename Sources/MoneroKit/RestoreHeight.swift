import Foundation

public class RestoreHeight {
    private static let DIFFICULTY_TARGET = 120
    private static let blockHeights: [String: Int64] = [
        "2014-05-01": 18844,
        "2014-06-01": 65406,
        "2014-07-01": 108_882,
        "2014-08-01": 153_594,
        "2014-09-01": 198_072,
        "2014-10-01": 241_088,
        "2014-11-01": 285_305,
        "2014-12-01": 328_069,
        "2015-01-01": 372_369,
        "2015-02-01": 416_505,
        "2015-03-01": 456_631,
        "2015-04-01": 501_084,
        "2015-05-01": 543_973,
        "2015-06-01": 588_326,
        "2015-07-01": 631_187,
        "2015-08-01": 675_484,
        "2015-09-01": 719_725,
        "2015-10-01": 762_463,
        "2015-11-01": 806_528,
        "2015-12-01": 849_041,
        "2016-01-01": 892_866,
        "2016-02-01": 936_736,
        "2016-03-01": 977_691,
        "2016-04-01": 1_015_848,
        "2016-05-01": 1_037_417,
        "2016-06-01": 1_059_651,
        "2016-07-01": 1_081_269,
        "2016-08-01": 1_103_630,
        "2016-09-01": 1_125_983,
        "2016-10-01": 1_147_617,
        "2016-11-01": 1_169_779,
        "2016-12-01": 1_191_402,
        "2017-01-01": 1_213_861,
        "2017-02-01": 1_236_197,
        "2017-03-01": 1_256_358,
        "2017-04-01": 1_278_622,
        "2017-05-01": 1_300_239,
        "2017-06-01": 1_322_564,
        "2017-07-01": 1_344_225,
        "2017-08-01": 1_366_664,
        "2017-09-01": 1_389_113,
        "2017-10-01": 1_410_738,
        "2017-11-01": 1_433_039,
        "2017-12-01": 1_454_639,
        "2018-01-01": 1_477_201,
        "2018-02-01": 1_499_599,
        "2018-03-01": 1_519_796,
        "2018-04-01": 1_542_067,
        "2018-05-01": 1_562_861,
        "2018-06-01": 1_585_135,
        "2018-07-01": 1_606_715,
        "2018-08-01": 1_629_017,
        "2018-09-01": 1_651_347,
        "2018-10-01": 1_673_031,
        "2018-11-01": 1_695_128,
        "2018-12-01": 1_716_687,
        "2019-01-01": 1_738_923,
        "2019-02-01": 1_761_435,
        "2019-03-01": 1_781_681,
        "2019-04-01": 1_803_081,
        "2019-05-01": 1_824_671,
        "2019-06-01": 1_847_005,
        "2019-07-01": 1_868_590,
        "2019-08-01": 1_890_878,
        "2019-09-01": 1_913_201,
        "2019-10-01": 1_934_732,
        "2019-11-01": 1_957_051,
        "2019-12-01": 1_978_433,
        "2020-01-01": 2_001_315,
        "2020-02-01": 2_023_656,
        "2020-03-01": 2_044_552,
        "2020-04-01": 2_066_806,
        "2020-05-01": 2_088_411,
        "2020-06-01": 2_110_702,
        "2020-07-01": 2_132_318,
        "2020-08-01": 2_154_590,
        "2020-09-01": 2_176_790,
        "2020-10-01": 2_198_370,
        "2020-11-01": 2_220_670,
        "2020-12-01": 2_242_241,
        "2021-01-01": 2_264_584,
        "2021-02-01": 2_286_892,
        "2021-03-01": 2_307_079,
        "2021-04-01": 2_329_385,
        "2021-05-01": 2_351_004,
        "2021-06-01": 2_373_306,
        "2021-07-01": 2_394_882,
        "2021-08-01": 2_417_162,
        "2021-09-01": 2_439_490,
        "2021-10-01": 2_461_020,
        "2021-11-01": 2_483_377,
        "2021-12-01": 2_504_932,
        "2022-01-01": 2_527_316,
        "2022-02-01": 2_549_605,
        "2022-03-01": 2_569_711,
        "2022-04-01": 2_591_995,
        "2022-05-01": 2_613_603,
        "2022-06-01": 2_635_840,
        "2022-07-01": 2_657_395,
        "2022-08-01": 2_679_705,
        "2022-09-01": 2_701_991,
        "2022-10-01": 2_723_607,
        "2022-11-01": 2_745_899,
        "2022-12-01": 2_767_427,
        "2023-01-01": 2_789_763,
        "2023-02-01": 2_811_996,
        "2023-03-01": 2_832_118,
        "2023-04-01": 2_854_365,
        "2023-05-01": 2_875_972,
        "2025-09-01": 3_490_175,
    ]

    public static func getHeight(date: Date) -> Int64 {
        (try? getHeightOrEstimate(date: date)) ?? 0
    }

    public static func maximumEstimatedHeight() -> Int64 {
        // getHeight estimates for now - 2 days, so we assume estimation for now + 2 days is accurate enough
        getHeight(date: Date() + TimeInterval(86400 * 4))
    }

    private static func getHeightOrEstimate(date: Date) throws -> Int64 {
        let utcTimeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone

        // Subtract 4 days to give some leeway
        guard let adjustedDate = calendar.date(byAdding: .day, value: -2, to: date) else {
            return 0
        }

        let year = calendar.component(.year, from: adjustedDate)
        let month = calendar.component(.month, from: adjustedDate)

        // Check if before May 2014 (month 5)
        if year < 2014 {
            return 0
        }
        if year == 2014, month <= 4 {
            return 0
        }

        let query = adjustedDate

        // Date formatter for UTC
        let formatter = DateFormatter()
        formatter.timeZone = utcTimeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let queryDate = formatter.string(from: date)

        // Get first day of the month
        let firstOfMonth = calendar.dateInterval(of: .month, for: adjustedDate)!.start
        let prevDate = formatter.string(from: firstOfMonth)

        // Lookup blockheight at first of the month
        var prevBc = Self.blockHeights[prevDate]
        var currentMonth = firstOfMonth

        if prevBc == nil {
            // If too recent, go back in time and find latest one we have
            while prevBc == nil {
                guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) else {
                    throw NSError(domain: "BlockheightError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "endless loop looking for blockheight"])
                }

                currentMonth = previousMonth
                let currentYear = calendar.component(.year, from: currentMonth)

                if currentYear < 2014 {
                    throw NSError(domain: "BlockheightError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "endless loop looking for blockheight"])
                }

                let currentDateString = formatter.string(from: currentMonth)
                prevBc = Self.blockHeights[currentDateString]
            }
        }

        var height = prevBc!
        let finalPrevDate = formatter.string(from: currentMonth)

        // Now we have a blockheight & a date ON or BEFORE the restore date requested
        if queryDate == finalPrevDate {
            return height
        }

        // See if we have a blockheight after this date
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) else {
            return height
        }

        let nextDate = formatter.string(from: nextMonth)
        let nextBc = Self.blockHeights[nextDate]

        if let nextBc {
            // We have a range - interpolate the blockheight we are looking for
            let diff = nextBc - height
            let timeDiff = nextMonth.timeIntervalSince(currentMonth)
            let diffDays = Int64(timeDiff / (24 * 60 * 60)) // Convert to days

            let queryTimeDiff = query.timeIntervalSince(currentMonth)
            let days = Int64(queryTimeDiff / (24 * 60 * 60))

            let blocksCount = Double(diff) * (Double(days) / Double(diffDays))
            height = Int64(round(Double(height) + blocksCount))
        } else {
            let queryTimeDiff = query.timeIntervalSince(currentMonth)
            let days = Int64(queryTimeDiff / (24 * 60 * 60))

            // Note: You'll need to define DIFFICULTY_TARGET constant
            let dailyBlocks = Double(24 * 60 * 60) / Double(DIFFICULTY_TARGET)
            height = Int64(round(Double(height) + Double(days) * dailyBlocks))
        }

        return height
    }
}
