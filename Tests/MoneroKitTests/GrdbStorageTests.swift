import XCTest
@testable import MoneroKit

/// Semantics of `GrdbStorage.databaseWasFreshlyCreated`.
///
/// `Kit.init` deletes the wallet2 cache directory (sole holder of
/// per-transaction keys) ONLY when this flag says the database file never
/// existed. These tests pin the three states that decision depends on:
/// fresh path, reopen, and the corrupt-file self-heal. If the self-heal
/// case ever reports `true`, a transient GRDB failure once again destroys
/// wallet caches — the Cullen bug.
final class GrdbStorageTests: XCTestCase {

    private var dbPath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrdbStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("storage").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
    }

    func testFreshPathReportsFreshlyCreated() {
        let storage = GrdbStorage(databaseFilePath: dbPath)
        XCTAssertTrue(storage.databaseWasFreshlyCreated)
        XCTAssertNil(storage.getBlockHeights(), "A fresh database has no heights row")
    }

    func testReopenReportsNotFreshlyCreated() {
        _ = GrdbStorage(databaseFilePath: dbPath)
        let reopened = GrdbStorage(databaseFilePath: dbPath)
        XCTAssertFalse(reopened.databaseWasFreshlyCreated)
    }

    func testCorruptFileSelfHealsButIsNotFreshlyCreated() throws {
        // Simulate the WAL-corruption / bad-header case: a file exists at
        // the path but is not a SQLite database.
        try Data("this is not a sqlite database, not even close".utf8)
            .write(to: URL(fileURLWithPath: dbPath))

        let storage = GrdbStorage(databaseFilePath: dbPath)
        XCTAssertFalse(
            storage.databaseWasFreshlyCreated,
            "Self-heal after a corrupt open must NOT look like a fresh wallet — Kit would delete the wallet2 cache and its tx keys"
        )
        // The self-heal must still yield a usable database.
        XCTAssertNil(storage.getBlockHeights())
        storage.update(blockHeights: BlockHeights(daemonHeight: 100, walletHeight: 42))
        XCTAssertNotNil(storage.getBlockHeights())
    }

    func testHeightsRoundTrip() {
        let storage = GrdbStorage(databaseFilePath: dbPath)
        storage.update(blockHeights: BlockHeights(daemonHeight: 3_669_455, walletHeight: 3_646_773))
        let heights = storage.getBlockHeights()
        XCTAssertEqual(heights?.walletHeight, 3_646_773)
        XCTAssertEqual(heights?.daemonHeight, 3_669_455)
    }
}
