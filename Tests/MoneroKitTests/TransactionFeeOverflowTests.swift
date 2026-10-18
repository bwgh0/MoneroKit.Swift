import XCTest
@testable import MoneroKit

/// A pre-RingCT (version 1) transaction that this wallet did not fully
/// fund gets a wallet2 fee of "our inputs minus all outputs" in unsigned
/// arithmetic, which wraps to a value just under 2^64. GRDB writes a
/// UInt64 as Int64 and traps above Int64.max, so before the fix one such
/// row crashed the app on every refresh of the Monero General Fund
/// view-only wallet. These tests feed that value through the storage.
final class TransactionFeeOverflowTests: XCTestCase {

    private var dbPath: String!

    /// Values wallet2 reported to the General Fund view-only wallet for
    /// version 1 transaction 0127fccf… (block 955075). The transaction
    /// spends 200 XMR to outputs of 199.99 XMR (0.01 XMR fee) and pays the
    /// fund 80 XMR. The fund owns none of its inputs, so the wallet2 fee
    /// is 0 - 199.99 XMR, which wraps to 2^64 - 199_990_000_000_000.
    private static let v1Hash = "0127fccfb3194a00c5d1a8729de49c11d70209f89438e67d0dfb2637595d399b"
    private static let v1Height: UInt64 = 955_075
    private static let v1Amount: Int64 = 80_000_000_000_000
    private static let wrappedFee: UInt64 = 18_446_544_083_709_551_616
    /// A second one from the same sync: f3141dfe… (block 953177), outputs
    /// of 0.29 XMR, 0.06 XMR to the fund.
    private static let secondWrappedFee: UInt64 = 18_446_743_783_709_551_616

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransactionFeeOverflowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("storage").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
    }

    private func incoming(hash: String, blockHeight: UInt64, amount: Int64, fee: UInt64) -> Transaction {
        Transaction(
            hash: hash, type: .incoming, blockHeight: blockHeight,
            amount: amount, fee: fee,
            isPending: false, isFailed: false, timestamp: 1_500_000_000,
            note: nil, recipientAddress: nil, subaddressIndices: [0]
        )
    }

    func testKnownFeeKeepsRealFeesAndDropsWrappedOnes() {
        XCTAssertEqual(Transaction.knownFee(0), 0)
        XCTAssertEqual(Transaction.knownFee(30_660_000), 30_660_000)
        XCTAssertEqual(Transaction.knownFee(UInt64(Int64.max)), UInt64(Int64.max))
        XCTAssertEqual(Transaction.knownFee(UInt64(Int64.max) + 1), 0)
        XCTAssertEqual(Transaction.knownFee(Self.wrappedFee), 0)
        XCTAssertEqual(Transaction.knownFee(Self.secondWrappedFee), 0)
        XCTAssertEqual(Transaction.knownFee(.max), 0)
    }

    /// The crash: one refresh that holds a wrapped fee. The write must
    /// complete, keep every row, and store the fee as 0 (unknown).
    func testRefreshWithWrappedFeeStoresEveryRow() throws {
        let storage = GrdbStorage(databaseFilePath: dbPath)
        let v1 = incoming(hash: Self.v1Hash, blockHeight: Self.v1Height, amount: Self.v1Amount, fee: Self.wrappedFee)
        let secondV1 = incoming(hash: "f3141dfe-v1", blockHeight: 953_177, amount: 60_000_000_000, fee: Self.secondWrappedFee)
        let rct = incoming(hash: "rct-incoming", blockHeight: 3_000_000, amount: 500_000_000_000, fee: 30_660_000)

        storage.update(transactions: [v1, secondV1, rct])

        let rows = storage.transactions(fromTimestamp: nil, descending: true, type: nil, limit: nil)
        XCTAssertEqual(Set(rows.map(\.hash)), [Self.v1Hash, "f3141dfe-v1", "rct-incoming"])
        XCTAssertEqual(storage.transaction(byHash: "f3141dfe-v1")?.fee, 0)

        let storedV1 = try XCTUnwrap(storage.transaction(byHash: Self.v1Hash))
        XCTAssertEqual(storedV1.fee, 0)
        XCTAssertEqual(storedV1.amount, Self.v1Amount)
        XCTAssertEqual(storedV1.blockHeight, Self.v1Height)
        XCTAssertEqual(TransactionInfo(transaction: storedV1).fee, 0)

        XCTAssertEqual(storage.transaction(byHash: "rct-incoming")?.fee, 30_660_000)
    }

    /// `fee` is a var: a value set after init must not trap on write either.
    func testFeeSetAfterInitStoresAsUnknown() throws {
        let storage = GrdbStorage(databaseFilePath: dbPath)
        let tx = incoming(hash: "late-fee", blockHeight: 10, amount: 1, fee: 1)
        tx.fee = .max

        storage.update(transactions: [tx])

        XCTAssertEqual(try XCTUnwrap(storage.transaction(byHash: "late-fee")).fee, 0)
    }

    /// No real height reaches Int64.max, but a write must not trap on one.
    func testHeightAboveInt64MaxIsClampedOnWrite() throws {
        let storage = GrdbStorage(databaseFilePath: dbPath)

        storage.update(transactions: [incoming(hash: "far-height", blockHeight: .max, amount: 1, fee: 0)])

        XCTAssertEqual(try XCTUnwrap(storage.transaction(byHash: "far-height")).blockHeight, UInt64(Int64.max))
    }
}
