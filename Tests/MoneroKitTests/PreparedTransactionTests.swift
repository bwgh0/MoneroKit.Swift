import HsToolKit
import XCTest
@testable import MoneroKit

/// A transaction from `prepareSend` is broadcast only in the wallet open it
/// was signed in, and once. The app's Send review keeps one while the user
/// reads its fee; a lock, a wallet switch or a second tap must never
/// broadcast a stale or spent one. Checked against a real wallet2 object
/// with no daemon (the node URL points at a closed local port). The guards
/// run before the pending-transaction pointer is touched, so these tests
/// use a placeholder pointer that is never read.
final class PreparedTransactionTests: XCTestCase {

    private var tempDir: URL!
    private var core: MoneroCore!
    private var placeholder: UnsafeMutableRawPointer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        placeholder = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)

        core = MoneroCore(
            wallet: .bip39(seed: Array(repeating: "abandon", count: 23) + ["art"], passphrase: ""),
            account: 0,
            walletPath: tempDir.appendingPathComponent("wallet").path,
            walletPassword: "pw",
            // Nothing listens on port 1, so every daemon call fails at once.
            node: Node(url: URL(string: "http://localhost:1")!, isTrusted: false),
            restoreHeight: 0,
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: nil
        )
    }

    override func tearDownWithError() throws {
        core?.stop()
        core = nil
        placeholder.deallocate()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func walletGeneration() throws -> Int {
        try XCTUnwrap(Mirror(reflecting: core!).descendant("walletGeneration") as? Int)
    }

    private func prepared(generation: Int) -> PreparedTransaction {
        PreparedTransaction(txids: ["00"], amount: 1, fee: 1, address: "4", pointer: placeholder,
                            walletGeneration: generation, memo: nil)
    }

    private func assertNothingSent(_ tx: PreparedTransaction, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try core.commit(tx), file: file, line: line) { error in
            guard case MoneroCoreError.walletNotInitialized = error else {
                return XCTFail("expected walletNotInitialized, got \(error)", file: file, line: line)
            }
        }
        XCTAssertFalse(tx.isUsed, "a refused commit must leave the transaction unsent", file: file, line: line)
    }

    func testPreparedInTheOpenWallet() throws {
        core.prepare()
        XCTAssertNotNil(core.getWalletPointer(), "wallet did not open")
        XCTAssertTrue(core.isPrepared(prepared(generation: try walletGeneration())))
    }

    func testCommitAfterTheWalletClosedSendsNothing() throws {
        core.prepare()
        let tx = prepared(generation: try walletGeneration())
        core.stop()

        XCTAssertFalse(core.isPrepared(tx))
        assertNothingSent(tx)
    }

    func testCommitFromAnEarlierOpenSendsNothing() throws {
        core.prepare()
        let tx = prepared(generation: try walletGeneration())
        core.stop()
        core.prepare()
        XCTAssertNotNil(core.getWalletPointer(), "wallet did not open again")

        XCTAssertFalse(core.isPrepared(tx), "a transaction signed in an earlier open must not go out")
        assertNothingSent(tx)
    }

    func testSentTransactionNeverCommitsTwice() throws {
        core.prepare()
        let tx = prepared(generation: try walletGeneration())
        tx.isUsed = true

        XCTAssertFalse(core.isPrepared(tx))
        XCTAssertThrowsError(try core.commit(tx)) { error in
            guard case MoneroCoreError.transactionSendFailed = error else {
                return XCTFail("expected transactionSendFailed, got \(error)")
            }
        }
    }

    /// With no daemon, building fails with an error the app can show: it
    /// never returns a transaction to broadcast.
    func testPrepareWithoutADaemonThrows() throws {
        core.prepare()
        XCTAssertNotNil(core.getWalletPointer(), "wallet did not open")
        let address = core.address(index: 0)
        XCTAssertFalse(address.isEmpty)
        XCTAssertThrowsError(try core.prepareSend(to: address, amount: .value(1_000_000_000), memo: nil))
    }
}
