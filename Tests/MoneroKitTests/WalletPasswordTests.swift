import CMonero
import HsToolKit
import XCTest
@testable import MoneroKit

/// The `.keys` password of a wallet2 file (docs/wallet-keys-password.md in
/// the app): older builds used the wallet id, which is the folder name and
/// sits in the app's UserDefaults, so the spend key was readable from the
/// app container. Now the caller passes a separate secret, and a file from
/// an older build is re-keyed to it on open.
///
/// Every wallet here is a real wallet2 file with no daemon (the node URL
/// points at a closed local port), except the tx-key test, which needs the
/// local regtest chain (`mo regtest`) and skips without it.
final class WalletPasswordTests: XCTestCase {

    private var tempDir: URL!
    private let secret = String(repeating: "a1", count: 32)
    private let legacyId = "0123456789abcdef0123456789abcdef"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalletPasswordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            chmodTree(tempDir, 0o755)
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private static let offlineNode = Node(url: URL(string: "http://localhost:1")!, isTrusted: false)

    private func bip39(_ passphrase: String) -> MoneroWallet {
        .bip39(seed: Array(repeating: "abandon", count: 23) + ["art"], passphrase: passphrase)
    }

    private func walletPath(_ name: String) throws -> String {
        let dir = tempDir.appendingPathComponent(name).appendingPathComponent("monero_core")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wallet").path
    }

    private func core(_ wallet: MoneroWallet, path: String, password: String, legacy: String? = nil, node: Node = offlineNode) -> MoneroCore {
        MoneroCore(
            wallet: wallet,
            account: 0,
            walletPath: path,
            walletPassword: password,
            legacyWalletPassword: legacy,
            node: node,
            restoreHeight: 0,
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: nil
        )
    }

    /// Opens the wallet the way `Kit` does and returns its primary address,
    /// or nil when it did not open. Closes it again (with a store).
    private func openAndClose(_ wallet: MoneroWallet, path: String, password: String, legacy: String? = nil) -> String? {
        let core = core(wallet, path: path, password: password, legacy: legacy)
        core.prepare()
        defer { core.stop() }
        guard core.getWalletPointer() != nil else { return nil }
        return core.address(index: 0)
    }

    /// What an older build left on disk: the file encrypted with `legacy`.
    private func makeLegacyWallet(_ wallet: MoneroWallet, path: String, legacy: String) throws -> String {
        let address = try XCTUnwrap(openAndClose(wallet, path: path, password: legacy), "legacy wallet did not open")
        XCTAssertTrue(opens(path, legacy))
        return address
    }

    private func opens(_ path: String, _ password: String) -> Bool {
        MONERO_WalletManager_verifyWalletPassword(MONERO_WalletManagerFactory_getWalletManager(), path + ".keys", password, true, 1)
    }

    private func movedAside(_ path: String) -> [String] {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.contains("unreadable") }
    }

    /// Makes every folder under `url` writable again, so a failed test that
    /// left one read-only still cleans up.
    private func chmodTree(_ url: URL, _ mode: mode_t) {
        chmod(url.path, mode)
        let items = FileManager.default.enumerator(atPath: url.path)?.compactMap { $0 as? String } ?? []
        for item in items {
            var isDir: ObjCBool = false
            let path = url.appendingPathComponent(item).path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                chmod(path, mode)
            }
        }
    }

    // MARK: - New wallets

    func testFreshWalletUsesTheGivenPassword() throws {
        let path = try walletPath("fresh")
        XCTAssertNotNil(openAndClose(bip39(""), path: path, password: secret, legacy: legacyId))

        XCTAssertTrue(opens(path, secret), "a new wallet is not encrypted with the given password")
        XCTAssertFalse(opens(path, legacyId), "a new wallet opens with the wallet id")
    }

    // MARK: - Migration

    func testLegacyWalletMigratesAndStillOpensAtTheNextLaunch() throws {
        let path = try walletPath("legacy")
        let address = try makeLegacyWallet(bip39(""), path: path, legacy: legacyId)

        // First launch of the new build: opens with the legacy password, re-keys.
        XCTAssertEqual(openAndClose(bip39(""), path: path, password: secret, legacy: legacyId), address)
        XCTAssertTrue(opens(path, secret), "the file was not re-keyed")
        XCTAssertFalse(opens(path, legacyId), "the wallet id still opens the file")

        // Second launch: opens with the secret.
        XCTAssertEqual(openAndClose(bip39(""), path: path, password: secret, legacy: legacyId), address)
        // The legacy password is not needed any more.
        XCTAssertEqual(openAndClose(bip39(""), path: path, password: secret), address)
        XCTAssertTrue(opens(path, secret))
        XCTAssertEqual(movedAside(path), [], "a readable wallet was moved aside")
    }

    func testFailedRekeyLeavesTheLegacyWalletOpenable() throws {
        let path = try walletPath("readonly")
        let address = try makeLegacyWallet(bip39(""), path: path, legacy: legacyId)
        let keysBefore = try Data(contentsOf: URL(fileURLWithPath: path + ".keys"))

        // wallet2 writes `wallet.keys.new` next to the file: a read-only
        // folder makes the re-key fail, as a full disk would.
        let walletDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        chmod(walletDir.path, 0o555)
        XCTAssertEqual(openAndClose(bip39(""), path: path, password: secret, legacy: legacyId), address,
                       "a failed re-key must not stop the wallet from opening")
        chmod(walletDir.path, 0o755)

        XCTAssertTrue(opens(path, legacyId), "the legacy password no longer opens the file")
        XCTAssertFalse(opens(path, secret))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + ".keys")), keysBefore, "the keys file changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the cache file is gone")
        XCTAssertEqual(movedAside(path), [])

        // The next launch tries again and succeeds.
        XCTAssertEqual(openAndClose(bip39(""), path: path, password: secret, legacy: legacyId), address)
        XCTAssertTrue(opens(path, secret))
        XCTAssertFalse(opens(path, legacyId))
    }

    func testEachWalletOfAMultiWalletInstallMigratesOnItsOwn() throws {
        let wallets = (0..<3).map { i in
            (wallet: bip39("wallet-\(i)"),
             legacy: String(format: "%032x", 0xabc0 + i),
             secret: String(repeating: String(format: "%02x", 0x10 + i), count: 32),
             name: "w\(i)")
        }
        var addresses: [String] = []
        var paths: [String] = []
        for w in wallets {
            let path = try walletPath(w.name)
            paths.append(path)
            addresses.append(try makeLegacyWallet(w.wallet, path: path, legacy: w.legacy))
        }
        XCTAssertEqual(Set(addresses).count, 3, "the three test wallets must differ")

        // The second wallet cannot be re-keyed at this launch; the others can.
        let lockedDir = URL(fileURLWithPath: paths[1]).deletingLastPathComponent()
        chmod(lockedDir.path, 0o555)
        for (i, w) in wallets.enumerated() {
            XCTAssertEqual(openAndClose(w.wallet, path: paths[i], password: w.secret, legacy: w.legacy), addresses[i])
        }
        chmod(lockedDir.path, 0o755)

        XCTAssertTrue(opens(paths[0], wallets[0].secret))
        XCTAssertTrue(opens(paths[1], wallets[1].legacy), "the failed wallet must keep its legacy password")
        XCTAssertFalse(opens(paths[1], wallets[1].secret))
        XCTAssertTrue(opens(paths[2], wallets[2].secret))
        // No wallet takes another wallet's password.
        for (i, path) in paths.enumerated() {
            for (j, w) in wallets.enumerated() where j != i {
                XCTAssertFalse(opens(path, w.secret), "wallet \(i) opens with the secret of wallet \(j)")
            }
        }

        // Next launch: the second one migrates, the others open with their secrets.
        for (i, w) in wallets.enumerated() {
            XCTAssertEqual(openAndClose(w.wallet, path: paths[i], password: w.secret, legacy: w.legacy), addresses[i])
            XCTAssertTrue(opens(paths[i], w.secret))
            XCTAssertFalse(opens(paths[i], w.legacy))
        }
    }

    func testViewOnlyWalletMigrates() throws {
        let path = try walletPath("view-only")
        // The view-only form of the bip39 test wallet.
        let full = try makeLegacyWallet(bip39(""), path: try walletPath("full"), legacy: legacyId)
        let fullCore = core(bip39(""), path: try walletPath("full"), password: legacyId)
        fullCore.prepare()
        let viewKey = try XCTUnwrap(fullCore.secretViewKey)
        fullCore.stop()

        let watch = MoneroWallet.watch(address: full, viewKey: viewKey)
        XCTAssertEqual(try makeLegacyWallet(watch, path: path, legacy: legacyId), full)
        XCTAssertEqual(openAndClose(watch, path: path, password: secret, legacy: legacyId), full)
        XCTAssertTrue(opens(path, secret))
        XCTAssertFalse(opens(path, legacyId))
    }

    /// A file that no password opens (a lost secret, or a corrupt file) is
    /// re-created from the credentials as before, but the old files are
    /// moved aside, not deleted: their cache holds the per-tx keys.
    func testUnreadableWalletIsMovedAsideNotDeleted() throws {
        let path = try walletPath("lost")
        let address = try makeLegacyWallet(bip39(""), path: path, legacy: "some-other-password-0123456789abcdef")
        let cacheBefore = try Data(contentsOf: URL(fileURLWithPath: path))

        XCTAssertEqual(openAndClose(bip39(""), path: path, password: secret, legacy: legacyId), address)
        XCTAssertTrue(opens(path, secret), "the re-created wallet does not use the secret")

        let aside = movedAside(path)
        XCTAssertEqual(aside.count, 1)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        let oldCache = parent.appendingPathComponent(aside[0]).appendingPathComponent("wallet")
        XCTAssertEqual(try Data(contentsOf: oldCache), cacheBefore, "the old cache was not kept as it was")
    }

    // MARK: - Kit

    func testKitRefusesAWeakPassword() throws {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defer { try? FileHandler.remove(for: "MoneroKit/\(id)") }
        for password in [id, "", "short-password"] {
            XCTAssertThrowsError(try Kit(wallet: bip39(""), account: 0, walletId: id, walletPassword: password,
                                         node: Self.offlineNode, reachabilityManager: ReachabilityManager(), logger: nil)) { error in
                guard case MoneroKitError.weakWalletPassword = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try FileHandler.directoryURL(for: "MoneroKit").appendingPathComponent(id).path),
                       "a refused Kit created files")
    }

    /// The Kit passes the wallet id as the legacy password: a file an older
    /// build left in the Kit's folder opens and is re-keyed.
    func testKitMigratesAFileAnOlderBuildLeft() async throws {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let base = "MoneroKit/\(id)/network_\(NetworkType.mainnet.rawValue)"
        defer { try? FileHandler.remove(for: "MoneroKit/\(id)") }

        // An older build's files: its database (with heights) and its wallet.
        do {
            let storage = GrdbStorage(databaseFilePath: try FileHandler.directoryURL(for: base).appendingPathComponent("storage").path)
            storage.update(blockHeights: BlockHeights(daemonHeight: 1, walletHeight: 1))
        }
        let path = try FileHandler.directoryURL(for: "\(base)/monero_core").appendingPathComponent("wallet").path
        let address = try makeLegacyWallet(bip39(""), path: path, legacy: id)

        let kit = try Kit(wallet: bip39(""), account: 0, walletId: id, walletPassword: secret,
                          node: Self.offlineNode, reachabilityManager: ReachabilityManager(), logger: nil)
        await kit.prepareOnly()
        XCTAssertEqual(kit.runtimePrimaryAddress, address)
        await kit.stopAsync()

        XCTAssertTrue(opens(path, secret), "the Kit did not re-key the file")
        XCTAssertFalse(opens(path, id), "the wallet id still opens the file")
    }

    // MARK: - Tx keys (regtest)

    /// send → migrate → the tx key is still there. The tx key exists only in
    /// the wallet2 cache file; a rescan cannot bring it back. Needs the local
    /// regtest chain: monerod on 18081, the faucet wallet-rpc on 18083 and
    /// the v1 proxy for mainnet wallets on 18095 (`mo regtest status`).
    func testTxKeysSurviveTheMigration() throws {
        let regtest = try Regtest.require()
        continueAfterFailure = false
        let path = try walletPath("txkey")
        let wm = MONERO_WalletManagerFactory_getWalletManager()

        // An older build's wallet with a sent transaction.
        let w = try XCTUnwrap(MONERO_WalletManager_createWallet(wm, path, legacyId, "English", NetworkType.mainnet.rawValue))
        // An early failure must still close the wallet: an open wallet2
        // with its refresh thread kept the test runner from exiting.
        var openWallet: UnsafeMutableRawPointer? = w
        defer { if let openWallet { MONERO_WalletManager_closeWallet(wm, openWallet, false) } }
        XCTAssertEqual(MONERO_Wallet_status(w), 0)
        let seed = try XCTUnwrap(stringFromCString(MONERO_Wallet_seed(w, "")))
        let address = try XCTUnwrap(stringFromCString(MONERO_Wallet_address(w, 0, 0)))
        XCTAssertTrue(MONERO_Wallet_init(w, regtest.walletNode, 0, "", "", false, false, ""))
        // A new mainnet wallet starts its scan at the mainnet height it
        // estimates from the date, far above the regtest tip.
        MONERO_Wallet_setRefreshFromBlockHeight(w, try regtest.height())
        // monero_c's wallet2 pulls no blocks until refresh is enabled.
        MONERO_Wallet_startRefresh(w)
        XCTAssertTrue(MONERO_Wallet_refresh(w))

        try regtest.fund(address: address, atomic: 2_000_000_000_000)
        try regtest.mine(blocks: 11)
        // wallet2 keeps the daemon height for up to 30 s, so a refresh right
        // after the blocks can stop short of them.
        let tip = try regtest.height()
        let deadline = Date().addingTimeInterval(120)
        while MONERO_Wallet_blockChainHeight(w) < tip, Date() < deadline {
            XCTAssertTrue(MONERO_Wallet_refresh(w), stringFromCString(MONERO_Wallet_errorString(w)) ?? "")
            if MONERO_Wallet_blockChainHeight(w) < tip { Thread.sleep(forTimeInterval: 5) }
        }
        XCTAssertGreaterThanOrEqual(MONERO_Wallet_blockChainHeight(w), tip, "the wallet did not sync to the regtest tip")
        XCTAssertGreaterThan(MONERO_Wallet_unlockedBalance(w, 0), 0, "the funds did not unlock")

        MONERO_Wallet_pauseRefresh(w)
        let pending = try XCTUnwrap(MONERO_Wallet_createTransaction(w, regtest.faucetAddress, "", 100_000_000_000, 0, 0, 0, "", ""))
        XCTAssertEqual(MONERO_PendingTransaction_status(pending), 0,
                       stringFromCString(MONERO_PendingTransaction_errorString(pending)) ?? "")
        // Read the id before the commit: commit empties the pending list,
        // and an empty list comes back as a string literal, not a heap copy.
        XCTAssertEqual(MONERO_PendingTransaction_txCount(pending), 1)
        let txId = try XCTUnwrap(stringFromCString(MONERO_PendingTransaction_txid(pending, ""))).prefix(64)
        XCTAssertEqual(txId.count, 64)
        XCTAssertTrue(MONERO_PendingTransaction_commit(pending, "", false))
        let txKey = try XCTUnwrap(stringFromCString(MONERO_Wallet_getTxKey(w, String(txId))))
        XCTAssertEqual(txKey.count, 64)
        try regtest.mine(blocks: 1)
        XCTAssertTrue(MONERO_Wallet_store(w, path))
        MONERO_WalletManager_closeWallet(wm, w, false)
        openWallet = nil
        XCTAssertTrue(opens(path, legacyId))

        // The new build opens it: migrate, then read the key.
        let credentials = MoneroWallet.legacy(seed: seed.split(separator: " ").map(String.init), passphrase: "")
        let node = Node(url: URL(string: regtest.walletNode)!, isTrusted: false)
        let migrated = core(credentials, path: path, password: secret, legacy: legacyId, node: node)
        migrated.prepare()
        XCTAssertEqual(migrated.address(index: 0), address)
        XCTAssertEqual(migrated.getTxKey(txId: String(txId)), txKey, "the tx key did not survive the migration")
        migrated.stop()
        XCTAssertTrue(opens(path, secret))
        XCTAssertFalse(opens(path, legacyId))

        // Second launch, with the secret only.
        let reopened = core(credentials, path: path, password: secret, node: node)
        reopened.prepare()
        XCTAssertEqual(reopened.getTxKey(txId: String(txId)), txKey, "the tx key is gone at the second launch")
        reopened.stop()
    }
}

/// The local regtest chain of `mo regtest`. No real funds.
private struct Regtest {
    let daemon = URL(string: "http://localhost:18081")!
    let faucet = URL(string: "http://localhost:18083")!
    /// The proxy that serves regtest blocks to mainnet wallets.
    let walletNode = "http://localhost:18095"
    let faucetAddress: String

    static func require() throws -> Regtest {
        guard let info = try? call(URL(string: "http://localhost:18081/get_info")!, nil, timeout: 3),
              info["status"] as? String == "OK" else {
            throw XCTSkip("regtest daemon is not running (mo regtest start)")
        }
        guard let proxy = try? call(URL(string: "http://localhost:18095/get_info")!, nil, timeout: 3),
              proxy["status"] as? String == "OK" else {
            throw XCTSkip("regtest proxy on 18095 is not running (mo regtest start)")
        }
        guard let result = try? rpc(URL(string: "http://localhost:18083")!, "get_address", [:]),
              let address = result["address"] as? String else {
            throw XCTSkip("regtest faucet wallet is not running (mo regtest start)")
        }
        return Regtest(faucetAddress: address)
    }

    func fund(address: String, atomic: UInt64) throws {
        _ = try Self.rpc(faucet, "transfer", ["destinations": [["amount": atomic, "address": address]], "priority": 0])
    }

    func height() throws -> UInt64 {
        let info = try Self.call(daemon.appendingPathComponent("get_info"), nil, timeout: 10)
        return try XCTUnwrap((info["height"] as? NSNumber)?.uint64Value)
    }

    func mine(blocks: Int) throws {
        _ = try Self.rpc(daemon, "generateblocks", ["amount_of_blocks": blocks, "wallet_address": faucetAddress])
    }

    private static func rpc(_ base: URL, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": "0", "method": method, "params": params]
        let reply = try call(base.appendingPathComponent("json_rpc"), body, timeout: 120)
        if let error = reply["error"] as? [String: Any] {
            throw NSError(domain: "regtest", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(method): \(error)"])
        }
        return try XCTUnwrap(reply["result"] as? [String: Any])
    }

    private static func call(_ url: URL, _ body: [String: Any]?, timeout: TimeInterval) throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.signal()
        }.resume()
        done.wait()
        let data = try XCTUnwrap(result).get()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
