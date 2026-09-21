import GRDB
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

    // MARK: - Transactions

    /// The last migration before the destination columns were added. A
    /// database migrated only this far is what every wallet synced by an
    /// older kit build has on disk.
    private static let preDestinationsMigration = "createBalance"

    private static let sendAddress = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
    private static let secondAddress = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
    private static let receiveSubaddress = "8BsubAddressOfThisWalletxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

    /// A database created by an older kit (no destination columns) must
    /// migrate in place and keep every existing row readable, with the
    /// new fields empty.
    func testOldSchemaRowsStayReadableAfterDestinationsMigration() throws {
        let dbQueue = try DatabaseQueue(path: dbPath)
        try GrdbStorage.migrator.migrate(dbQueue, upTo: Self.preDestinationsMigration)
        try dbQueue.write { db in
            let columns = try db.columns(in: Transaction.databaseTableName).map(\.name)
            XCTAssertFalse(columns.contains(Transaction.Columns.destinations.name), "Fixture must reproduce the old schema")
            XCTAssertFalse(columns.contains(Transaction.Columns.subaddressIndices.name))
            XCTAssertFalse(columns.contains(Transaction.Columns.subaddressAccount.name))
            try db.execute(
                sql: """
                INSERT INTO transactions
                    (uid, hash, type, blockHeight, amount, fee, isPending, isFailed, timestamp, note, recipientAddress)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["uid-out", "hash-out", TransactionType.outgoing.rawValue, 3_000_000, -1_500_000_000_000, 30_000_000, false, false, 1_700_000_000, "lunch", nil]
            )
            try db.execute(
                sql: """
                INSERT INTO transactions
                    (uid, hash, type, blockHeight, amount, fee, isPending, isFailed, timestamp, note, recipientAddress)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["uid-in", "hash-in", TransactionType.incoming.rawValue, 3_000_005, 500_000_000_000, 0, false, false, 1_700_000_500, nil, Self.receiveSubaddress]
            )
        }
        try dbQueue.close()

        let storage = GrdbStorage(databaseFilePath: dbPath)
        XCTAssertFalse(storage.databaseWasFreshlyCreated)

        let rows = storage.transactions(fromTimestamp: nil, descending: true, type: nil, limit: nil)
        XCTAssertEqual(rows.map(\.hash), ["hash-in", "hash-out"])

        let outgoing = try XCTUnwrap(storage.transaction(byHash: "hash-out"))
        XCTAssertEqual(outgoing.type, .outgoing)
        XCTAssertEqual(outgoing.amount, -1_500_000_000_000)
        XCTAssertEqual(outgoing.fee, 30_000_000)
        XCTAssertEqual(outgoing.note, "lunch")
        XCTAssertNil(outgoing.recipientAddress)
        XCTAssertEqual(outgoing.destinations, [])
        XCTAssertEqual(outgoing.subaddressIndices, [])
        XCTAssertEqual(outgoing.subaddressAccount, 0)

        let incoming = try XCTUnwrap(storage.transaction(byHash: "hash-in"))
        XCTAssertEqual(incoming.recipientAddress, Self.receiveSubaddress)
        XCTAssertEqual(incoming.destinations, [])
        XCTAssertEqual(incoming.subaddressIndices, [])

        // The public model built from a migrated row carries the empty defaults.
        let info = TransactionInfo(transaction: outgoing)
        XCTAssertEqual(info.destinations, [])
        XCTAssertEqual(info.subaddressIndices, [])
        XCTAssertEqual(info.subaddressAccount, 0)

        // A refresh rewrites the table with the migrated rows; that must work too.
        storage.update(transactions: rows)
        XCTAssertEqual(storage.transactions(fromTimestamp: nil, descending: true, type: nil, limit: nil).count, 2)
    }

    /// Destinations and subaddress indices survive a write, a read, and a
    /// reopen of the database.
    func testDestinationsAndSubaddressIndicesRoundTrip() throws {
        let storage = GrdbStorage(databaseFilePath: dbPath)
        let destinations = [
            TransactionDestination(address: Self.sendAddress, amount: 1_000_000_000_000),
            TransactionDestination(address: Self.secondAddress, amount: 250_000_000_000),
        ]
        let outgoing = Transaction(
            hash: "out-1", type: .outgoing, blockHeight: 3_000_001,
            amount: -1_250_030_000_000, fee: 30_000_000,
            isPending: false, isFailed: false, timestamp: 1_700_000_100,
            note: nil, recipientAddress: nil,
            destinations: destinations, subaddressIndices: [0, 3], subaddressAccount: 0
        )
        let incoming = Transaction(
            hash: "in-1", type: .incoming, blockHeight: 3_000_002,
            amount: 500_000_000_000, fee: 0,
            isPending: false, isFailed: false, timestamp: 1_700_000_200,
            note: "rent", recipientAddress: Self.receiveSubaddress,
            destinations: [], subaddressIndices: [3], subaddressAccount: 0
        )
        storage.update(transactions: [outgoing, incoming])

        let loadedOut = try XCTUnwrap(storage.transaction(byHash: "out-1"))
        XCTAssertEqual(loadedOut.destinations, destinations)
        XCTAssertEqual(loadedOut.subaddressIndices, [0, 3])
        XCTAssertEqual(loadedOut.subaddressAccount, 0)
        XCTAssertNil(loadedOut.recipientAddress)

        let loadedIn = try XCTUnwrap(storage.transaction(byHash: "in-1"))
        XCTAssertEqual(loadedIn.destinations, [])
        XCTAssertEqual(loadedIn.subaddressIndices, [3])
        XCTAssertEqual(loadedIn.recipientAddress, Self.receiveSubaddress)

        let info = TransactionInfo(transaction: loadedOut)
        XCTAssertEqual(info.destinations, destinations)
        XCTAssertEqual(info.subaddressIndices, [0, 3])
        XCTAssertEqual(info.subaddressAccount, 0)

        // Reopen: the values come back from disk, not from the record instances.
        let reopened = GrdbStorage(databaseFilePath: dbPath)
        XCTAssertFalse(reopened.databaseWasFreshlyCreated)
        XCTAssertEqual(reopened.transaction(byHash: "out-1")?.destinations, destinations)
        XCTAssertEqual(reopened.transaction(byHash: "in-1")?.subaddressIndices, [3])
    }

    /// A non-zero account round-trips and the nullable integer column
    /// still reads as 0 when written as NULL.
    func testSubaddressAccountRoundTrip() throws {
        let storage = GrdbStorage(databaseFilePath: dbPath)
        let tx = Transaction(
            hash: "acct-2", type: .incoming, blockHeight: 1, amount: 1, fee: 0,
            isPending: false, isFailed: false, timestamp: 1, note: nil,
            recipientAddress: nil, subaddressIndices: [1], subaddressAccount: 2
        )
        storage.update(transactions: [tx])
        XCTAssertEqual(storage.transaction(byHash: "acct-2")?.subaddressAccount, 2)

        try storage.dbPool.write { db in
            try db.execute(sql: "UPDATE transactions SET subaddressAccount = NULL, subaddressIndices = NULL, destinations = NULL")
        }
        let cleared = try XCTUnwrap(storage.transaction(byHash: "acct-2"))
        XCTAssertEqual(cleared.subaddressAccount, 0)
        XCTAssertEqual(cleared.subaddressIndices, [])
        XCTAssertEqual(cleared.destinations, [])
    }
}
