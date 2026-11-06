import CMonero
import Combine
import Foundation
import HsToolKit

class MoneroCore {
    weak var delegate: MoneroCoreDelegate?

    private let globalEventQueue = DispatchQueue.global(qos: .userInteractive)
    private let refreshQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.core_refresh_queue", qos: .utility)
    /// Every start and pause of wallet2's refresh thread goes through it.
    let refreshGate = RefreshGate()
    /// Set from `pauseSync` until `startSync`.
    private let callerPause = CallerPause()

    private var wallet: MoneroWallet
    private(set) var stateManager: SyncStateManager
    private var walletListener: WalletListener
    private var networkType: NetworkType = .mainnet
    private var walletManagerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer? {
        didSet { walletGeneration = Self.nextWalletGeneration() }
    }
    /// Changes on every wallet open and close, unique across every kit in
    /// the process (a new kit for the same wallet never reuses one). A
    /// `PreparedTransaction` commits only in the open it was signed in.
    private var walletGeneration = MoneroCore.nextWalletGeneration()
    private static let walletGenerationLock = NSLock()
    private static var lastWalletGeneration = 0
    private static func nextWalletGeneration() -> Int {
        walletGenerationLock.lock()
        defer { walletGenerationLock.unlock() }
        lastWalletGeneration &+= 1
        return lastWalletGeneration
    }
    /// True once the wallet opened/recovered with status == 0. Gates the
    /// store-on-close in `stopCore()`: a wallet that never opened cleanly
    /// (corrupt cache, unreachable hardware device) must not serialize its
    /// empty in-memory state over a previously good cache file — that file
    /// is the only holder of per-transaction keys.
    private var walletOpenedCleanly = false
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private let logger: Logger?
    private let moneroCoreLogLevel: Int32? // 0..4
    private var restoreHeight: UInt64 = 0
    var account: UInt32
    var node: Node

    /// The actual refresh-from-block-height set by the C++ wallet (e.g. decoded from Polyseed birthday)
    var actualRefreshFromBlockHeight: UInt64 {
        guard let walletPtr = walletPointer else { return restoreHeight }
        return MONERO_Wallet_getRefreshFromBlockHeight(walletPtr)
    }

    private var transactions: [Transaction] = [] {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.transactionsDidChange(transactions: transactions)
            }
        }
    }

    private var subAddresses: [SubAddress] = [] {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.subAddresssesDidChange(subAddresses: subAddresses)
            }
        }
    }

    /// nil until the first read after the wallet opens, so that read always
    /// publishes. Until then the app shows the balance stored by the last
    /// run; a wallet emptied elsewhere reads 0, and a default of 0 here hid
    /// that change and kept the stale balance on screen.
    private var balance: Balance? {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self, let balance, oldValue != balance else { return }
                delegate?.balanceDidChange(balance: balance)
            }
        }
    }

    var state: WalletState {
        stateManager.state
    }

    var blockHeights: (UInt64, UInt64)? {
        stateManager.blockHeights
    }

    /// True when the wallet has no spend key (created from address + view key).
    /// Send / sign operations are rejected by wallet2 for view-only wallets.
    var isWatchOnly: Bool {
        guard let walletPtr = walletPointer else { return false }
        return MONERO_Wallet_watchOnly(walletPtr)
    }

    /// The wallet's private view key as a 64-char lowercase hex string, or
    /// nil if no wallet is currently open. Safe to expose — the view key
    /// alone cannot authorize spending.
    var secretViewKey: String? {
        guard let walletPtr = walletPointer else { return nil }
        return stringFromCString(MONERO_Wallet_secretViewKey(walletPtr))
    }

    /// Internal accessor for wallet pointer
    func getWalletPointer() -> UnsafeMutableRawPointer? {
        return walletPointer
    }

    init(wallet: MoneroWallet, account: UInt32, walletPath: String, walletPassword: String, node: Node, restoreHeight: UInt64, networkType: NetworkType, reachabilityManager: ReachabilityManager, logger: Logger?, moneroCoreLogLevel: Int32?) {
        self.wallet = wallet
        self.account = account
        cWalletPath = strdup((walletPath as NSString).utf8String)
        cWalletPassword = strdup((walletPassword as NSString).utf8String)
        self.node = node
        self.restoreHeight = restoreHeight
        self.networkType = networkType
        self.logger = logger
        self.moneroCoreLogLevel = moneroCoreLogLevel
        stateManager = SyncStateManager(logger: logger, restoreHeight: restoreHeight, reachabilityManager: reachabilityManager)
        walletListener = WalletListener()
        walletManagerPointer = MONERO_WalletManagerFactory_getWalletManager()

        bindCallbacks()
    }

    /// Connect the state manager and wallet listener events to this core.
    /// `stopWalletServices()` clears them, so no callback runs against a
    /// closed wallet.
    private func bindCallbacks() {
        stateManager.onSyncStateChanged = { [weak self] in
            self?.onSyncStateChanged()
        }

        walletListener.onNewTransaction = { [weak self] in
            self?.startStateManager()
        }

        walletListener.onNewBlock = { [weak self] in
            self?.startStateManager()
        }
    }

    deinit {
        wallet.clear()

        // Free non-sensitive data
        if let ptr = cWalletPassword { free(ptr) }
        if let ptr = cWalletPath { free(ptr) }
    }

    private func startStateManager() {
        guard let walletPointer, let cWalletPassword else { return }

        stateManager.start(walletPointer: walletPointer, cWalletPassword: cWalletPassword)
    }

    private func openWallet() throws {
        if let moneroCoreLogLevel {
            MONERO_WalletManagerFactory_setLogLevel(moneroCoreLogLevel)
        }

        guard let walletManagerPointer, let cWalletPath else { return }

        let walletExists = MONERO_WalletManager_walletExists(walletManagerPointer, cWalletPath)
        var recoveredWalletPtr: UnsafeMutableRawPointer?

        if walletExists {
            recoveredWalletPtr = MONERO_WalletManager_openWallet(walletManagerPointer, cWalletPath, cWalletPassword, networkType.rawValue)

            // wallet2's openWallet returns a non-null Wallet even when the
            // `.keys` file failed to load or decrypt — the error lives in
            // status() and the account keys stay default-constructed (all
            // zeros). Using that object anyway serves the null-key address
            // to the UI and burns anything sent to it. If we still hold the
            // credentials (every source except a hardware device), discard
            // the broken object, wipe the unreadable files, and re-derive
            // the wallet from the credentials — same keys, at worst a
            // rescan and the loss of stored per-tx keys.
            let openStatus: Int32 = recoveredWalletPtr.map { MONERO_Wallet_status($0) } ?? 1
            var canRecreate: Bool {
                if case .trezor = wallet { return false }
                return true
            }
            if openStatus != 0, canRecreate {
                let msg = recoveredWalletPtr
                    .flatMap { stringFromCString(MONERO_Wallet_errorString($0)) } ?? "open returned null"
                NSLog("[MoneroCore] ERROR opening existing wallet (status=\(openStatus)): \(msg) — recreating from credentials")
                logger?.error("Error opening existing wallet (status=\(openStatus)): \(msg) — recreating from credentials")

                if let brokenPtr = recoveredWalletPtr {
                    // store=false: never let a keyless wallet object overwrite
                    // the on-disk files.
                    MONERO_WalletManager_closeWallet(walletManagerPointer, brokenPtr, false)
                    recoveredWalletPtr = nil
                }

                let walletDir = URL(fileURLWithPath: String(cString: cWalletPath)).deletingLastPathComponent()
                try? FileManager.default.removeItem(at: walletDir)
                try? FileManager.default.createDirectory(at: walletDir, withIntermediateDirectories: true)

                recoveredWalletPtr = try createWalletFromCredentials()
            }
        } else {
            recoveredWalletPtr = try createWalletFromCredentials()
        }

        guard let walletPtr = recoveredWalletPtr else {
            let errorCStr = MONERO_WalletManager_errorString(walletManagerPointer)
            let msg = stringFromCString(errorCStr) ?? "Unknown recovery error"
            NSLog("[MoneroCore] ERROR recovering wallet: \(msg)")
            logger?.error("Error recovering wallet: \(msg)")
            throw MoneroCoreError.walletStatusError(msg)
        }

        let walletStatus = MONERO_Wallet_status(walletPtr)
        if walletStatus != 0 {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown wallet error"
            NSLog("[MoneroCore] Wallet status after creation: status=\(walletStatus), error=\(msg)")
            logger?.error("Wallet status after creation: \(walletStatus) \(msg)")

            // Only a device-bound wallet may keep a pointer in an error
            // state: createWalletFromDevice legitimately returns one when
            // the Trezor bridge isn't reachable yet, and the object becomes
            // usable once the device session reconnects. For every software
            // source an error status means the keys are not the wallet's
            // keys — fail the open rather than expose a keyless wallet.
            guard case .trezor = wallet else {
                MONERO_WalletManager_closeWallet(walletManagerPointer, walletPtr, false)
                throw MoneroCoreError.walletStatusError(msg)
            }
        } else if case .trezor = wallet {} else {
            // Belt and suspenders: even with status 0, refuse to run a
            // software wallet whose keys read as zero — its receive address
            // would be the null-key address and funds sent there are burned.
            let viewKey = stringFromCString(MONERO_Wallet_secretViewKey(walletPtr))
            let primary = stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0)) ?? ""
            if viewKey == NullKeyAddress.zeroSecretKey || NullKeyAddress.isNullKey(primary) {
                NSLog("[MoneroCore] ERROR wallet opened with null keys — refusing to use it")
                logger?.error("Wallet opened with null keys — refusing to use it")
                MONERO_WalletManager_closeWallet(walletManagerPointer, walletPtr, false)
                throw MoneroCoreError.walletStatusError("Wallet keys failed to load")
            }
        }

        walletOpenedCleanly = walletStatus == 0

        // Set wallet pointer immediately after recovery — address derivation
        // only needs the wallet2 object, not a daemon connection.
        walletPointer = walletPtr
        wallet.clear()

        // Don't NSLog the primary address — combined with the balance
        // log in updateBalance it produces an address+balance pair in
        // the unified system log, which is a deanonymization vector
        // if log access is ever compromised. Keep address derivation
        // for the sync path that does need it elsewhere.
        _ = stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0))
    }

    /// Create the wallet2 files at `cWalletPath` from the in-memory
    /// credentials. Callable only while `wallet` still holds them (before
    /// `wallet.clear()` runs at the end of a successful open).
    private func createWalletFromCredentials() throws -> UnsafeMutableRawPointer? {
        guard let walletManagerPointer, let cWalletPath else { return nil }

        var recoveredWalletPtr: UnsafeMutableRawPointer?

        switch wallet {
        case let .bip39(mnemonic, passphrase):
            // Recover directly from the derived spend key instead of going
            // spend key → 25 words → wallet2 words_to_bytes → spend key.
            // The words leg ran through Wallet::bytesToWords, a fork addition
            // the current library builds stub out to return "" — the empty
            // mnemonic made wallet2's recovery fail and every BIP39 wallet
            // came up keyless (the null-address burn bug).
            // `recoverDeterministicWalletFromSpendKey` calls
            // wallet2::generate(spendkey, recover=true), the exact operation
            // a 25-word restore performs after decoding, so keys are
            // identical to what the words path produced when it worked.
            let spendKeyHex = try spendKeyHexFromBip39(mnemonic: mnemonic, passphrase: passphrase)

            recoveredWalletPtr = MONERO_WalletManager_createDeterministicWalletFromSpendKey(
                walletManagerPointer,
                cWalletPath,
                cWalletPassword,
                "English",
                networkType.rawValue,
                restoreHeight,
                (spendKeyHex as NSString).utf8String,
                1
            )

        case let .legacy(mnemonic, passphrase):
            // NFC: wallet2 matches words byte for byte against its NFC word
            // lists. NFKD split accented, umlauted, dakuten and й/ё letters,
            // so Spanish, German, Japanese and Russian restores with such a
            // word failed.
            let seed = mnemonic.joined(separator: " ").precomposedStringWithCanonicalMapping

            recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                walletManagerPointer,
                cWalletPath,
                cWalletPassword,
                (seed as NSString).utf8String,
                networkType.rawValue,
                restoreHeight,
                1,
                passphrase
            )

        case let .polyseed(mnemonic, passphrase):
            let seed = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping

            recoveredWalletPtr = MONERO_WalletManager_createWalletFromPolyseed(
                walletManagerPointer,
                cWalletPath,
                cWalletPassword,
                networkType.rawValue,
                (seed as NSString).utf8String,
                passphrase,
                false,
                restoreHeight,
                1
            )

        case let .watch(address, viewKey):
            recoveredWalletPtr = MONERO_WalletManager_createWalletFromKeys(
                walletManagerPointer,
                cWalletPath,
                cWalletPassword,
                "",
                networkType.rawValue,
                restoreHeight,
                (address as NSString).utf8String,
                (viewKey as NSString).utf8String,
                "",
                1
            )

        case let .trezor(deviceName):
            recoveredWalletPtr = MONERO_WalletManager_createWalletFromDevice(
                walletManagerPointer,
                cWalletPath,
                cWalletPassword,
                networkType.rawValue,
                (deviceName as NSString).utf8String,
                restoreHeight,
                "5:20",
                "",
                "",
                1
            )
        }

        return recoveredWalletPtr
    }

    /// Connect wallet to daemon. Requires wallet to be opened first via openWallet().
    /// This is the slow part — network connection to the remote node.
    private func connectDaemon() {
        guard let walletPtr = walletPointer else { return }

        let cDaemonAddress = strdup((node.url.absoluteString as NSString).utf8String)
        let cDaemonLogin = strdup(((node.login ?? "") as NSString).utf8String)
        let cDaemonPassword = strdup(((node.password ?? "") as NSString).utf8String)
        let cProxy = strdup(((node.proxy ?? "") as NSString).utf8String)
        let useSSL = node.url.scheme?.lowercased() == "https"
        NSLog("[MoneroCore] Initializing wallet with daemon: \(node.url.absoluteString), useSSL=\(useSSL), proxy=\(node.proxy ?? "none")")
        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, cDaemonLogin, cDaemonPassword, useSSL, false, cProxy)
        free(cProxy)
        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            NSLog("[MoneroCore] ERROR initializing wallet with daemon: \(msg)")
            logger?.error("Error initializing wallet with daemon: \(msg)")
            return
        }
        NSLog("[MoneroCore] Wallet initialized successfully with daemon, self=\(Unmanaged.passUnretained(self).toOpaque())")

        // wallet2 reads a wallet with no synced blocks (a cache stored
        // before the first sync, e.g. the app was killed during a
        // restore) as a brand new wallet, and init moves its refresh
        // height to the daemon tip. The scan then starts at the tip and
        // misses every earlier transaction. Put the saved restore height
        // back before the refresh thread starts.
        let chainHeight = MONERO_Wallet_blockChainHeight(walletPtr)
        let refreshHeight = MONERO_Wallet_getRefreshFromBlockHeight(walletPtr)
        if let height = Self.refreshHeightAfterInit(blockChainHeight: chainHeight, refreshHeight: refreshHeight, restoreHeight: restoreHeight) {
            NSLog("[MoneroCore] Wallet has no synced blocks, refresh height %llu moved by init, restoring %llu", refreshHeight, height)
            logger?.info("Wallet has no synced blocks: restored the refresh height \(height) (init set \(refreshHeight))")
            MONERO_Wallet_setRefreshFromBlockHeight(walletPtr, height)
        }

        MONERO_Wallet_setTrustedDaemon(walletPtr, node.isTrusted)
    }

    /// The refresh height to set after `MONERO_Wallet_init`, or nil when
    /// init left it alone. A wallet whose cache holds at most the genesis
    /// block scans from its saved restore height, never from the tip that
    /// wallet2's new-wallet rule picks.
    static func refreshHeightAfterInit(blockChainHeight: UInt64, refreshHeight: UInt64, restoreHeight: UInt64) -> UInt64? {
        guard blockChainHeight <= 1, refreshHeight != restoreHeight else { return nil }
        return restoreHeight
    }

    private func onSyncStateChanged() {
        // Early exit if wallet is already closed to prevent use-after-free
        guard walletPointer != nil else { return }

        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.walletStateDidChange(state: state)
        }

        switch state {
        case .connecting, .notSynced: ()

        case .synced:
            // Stop polling only. `stop()` here also paused wallet2's refresh
            // and cleared this callback, so an open synced wallet never saw
            // another block and its confirmations froze.
            stateManager.stopPolling()
            refreshQueue.async { [weak self] in
                self?.refresh()
                self?.stateManager.walletStored()
            }

        case .syncing:
            if stateManager.chunkOfBlocksSynced {
                refreshQueue.async { [weak self] in
                    self?.refresh(isSyncChunk: true)
                    self?.stateManager.walletStored()
                }
            }

        case let .idle(daemonReachable):
            if daemonReachable {
                // Paused by the caller (Trusted Locations, background): the
                // network's return must not start sync. `startSync` does.
                guard !callerPause.deferServices() else {
                    NSLog("[MoneroCore] network back while sync is paused: services start at the next startSync")
                    return
                }
                startWalletServices()
            } else {
                // The network went down again: `startSync` takes its usual path.
                callerPause.servicesStopped()
                stopWalletServices()
                // The wallet stays open while the network is down. Bind the
                // callbacks again, or the .idle(daemonReachable: true) of the
                // returning network never reaches this switch and the wallet
                // never syncs again.
                bindCallbacks()
            }
        }
    }

    /// Held, the store's LOCK_REFRESH reads the refresh as off and never
    /// starts it again itself: the gate does, and only while sync is on.
    /// Without the hold, a store that waited for the refresh across a
    /// `pauseSync` started the refresh again when it ended.
    private func storeWallet(walletPointer: UnsafeMutableRawPointer) {
        refreshGate.hold(walletPointer)
        defer { refreshGate.release(walletPointer) }
        _ = MONERO_Wallet_store(walletPointer, cWalletPath)
    }

    private func updateBalance(walletPointer: UnsafeMutableRawPointer) {
        let allBalance = MONERO_Wallet_balance(walletPointer, account)
        let unlocked = MONERO_Wallet_unlockedBalance(walletPointer, account)
        // Intentionally no NSLog of balance values. See note in
        // setupWalletKit re: address+balance correlation in syslog.
        balance = Balance(all: allBalance, unlocked: unlocked)
    }

    private func fetchSubaddresses(walletPointer: UnsafeMutableRawPointer) {
        var fetchedAddresses: [SubAddress] = []
        let count = MONERO_Wallet_numSubaddresses(walletPointer, account)

        for i in 0 ..< count {
            // The null-key check keeps a keyless wallet2 object (keys file
            // never loaded) from pushing the burn address into storage —
            // it base58-encodes as a non-empty, superficially valid string.
            if let address = stringFromCString(MONERO_Wallet_address(walletPointer, UInt64(account), UInt64(i))),
               !address.isEmpty, !NullKeyAddress.isNullKey(address) {
                let label = stringFromCString(MONERO_Wallet_getSubaddressLabel(walletPointer, account, UInt32(i))) ?? ""
                fetchedAddresses.append(.init(address: address, index: i, label: label))
            }
        }

        // Don't propagate if C++ returned no valid addresses — it's not ready yet
        guard !fetchedAddresses.isEmpty else { return }
        subAddresses = fetchedAddresses
    }

    private func fetchTransactions(walletPointer: UnsafeMutableRawPointer, skipNotes: Bool = false) {
        let historyPtr = MONERO_Wallet_history(walletPointer)
        MONERO_TransactionHistory_refresh(historyPtr)

        let count = MONERO_TransactionHistory_count(historyPtr)
        var fetchedTransactions: [Transaction] = []

        for i in 0 ..< count {
            let txInfoPtr = MONERO_TransactionHistory_transaction(historyPtr, i)

            guard let direction = Transaction.Direction(rawValue: MONERO_TransactionInfo_direction(txInfoPtr)) else { continue }
            let hash = stringFromCString(MONERO_TransactionInfo_hash(txInfoPtr)) ?? "N/A"

            var transfers: [Transfer] = []
            let transferCount = MONERO_TransactionInfo_transfers_count(txInfoPtr)

            if transferCount > 0 {
                for j in 0 ..< transferCount {
                    let transferAmount = MONERO_TransactionInfo_transfers_amount(txInfoPtr, j)
                    let address = stringFromCString(MONERO_TransactionInfo_transfers_address(txInfoPtr, j)) ?? ""
                    transfers.append(Transfer(address: address, amount: transferAmount))
                }
            }

            var subaddrIndices: [Int] = []
            if let subaddrIndicesStr = stringFromCString(MONERO_TransactionInfo_subaddrIndex(txInfoPtr, " ")) {
                subaddrIndices = subaddrIndicesStr.split(separator: " ").compactMap { Int($0) }
            }

            var note: String?
            if !skipNotes {
                note = stringFromCString(MONERO_Wallet_getUserNote(walletPointer, hash))
                if let _note = note, _note.isEmpty { note = nil }
            }

            let transaction = Transaction(
                direction: direction,
                isPending: MONERO_TransactionInfo_isPending(txInfoPtr),
                isFailed: MONERO_TransactionInfo_isFailed(txInfoPtr),
                amount: MONERO_TransactionInfo_amount(txInfoPtr),
                fee: MONERO_TransactionInfo_fee(txInfoPtr),
                subaddrIndices: subaddrIndices,
                subaddrAccount: MONERO_TransactionInfo_subaddrAccount(txInfoPtr),
                blockHeight: MONERO_TransactionInfo_blockHeight(txInfoPtr),
                confirmations: MONERO_TransactionInfo_confirmations(txInfoPtr),
                hash: hash,
                timestamp: Date(timeIntervalSince1970: TimeInterval(MONERO_TransactionInfo_timestamp(txInfoPtr))),
                note: note,
                transfers: transfers
            )

            if transaction.subaddrAccount == account {
                fetchedTransactions.append(transaction)
            }
        }

        transactions = fetchedTransactions.sorted(by: { $0.timestamp > $1.timestamp })

        // Biggest number of confirmations amoung unconfirmed (less than 10 blocks) transactions
        var biggestConfirmations: UInt64 = 0
        var hasUnconfirmedTransactions = false

        for transaction in transactions {
            if transaction.confirmations >= Kit.confirmationsThreshold {
                continue
            }

            if transaction.confirmations > biggestConfirmations {
                biggestConfirmations = transaction.confirmations
                hasUnconfirmedTransactions = true
            }
        }

        if hasUnconfirmedTransactions, biggestConfirmations < Kit.confirmationsThreshold,
           stateManager.walletHeight >= biggestConfirmations {
            walletListener.setLockedBalanceHeight(height: stateManager.walletHeight - biggestConfirmations)
        }
    }

    private func startCore() {
        guard walletPointer == nil else { return }
        do {
            try openWallet()

            // After wallet is open, read the actual refresh height set by the C++ library.
            // For Polyseed wallets this is the decoded birthday — use it instead of whatever
            // was passed in, so progress calculations and UI display are correct.
            if let wp = walletPointer {
                let cppHeight = MONERO_Wallet_getRefreshFromBlockHeight(wp)
                if cppHeight > 0 && cppHeight != restoreHeight {
                    #if DEBUG
                    NSLog("[MoneroCore] C++ refreshFromBlockHeight=%llu (was %llu), updating", cppHeight, restoreHeight)
                    #endif
                    restoreHeight = cppHeight
                    stateManager.updateRestoreHeight(cppHeight)
                    delegate?.restoreHeightUpdated(height: cppHeight)
                }
            }
        } catch {
            stateManager.state = .notSynced(error: .startError(error.localizedDescription))
        }
    }

    private func stopCore() {
        guard let wmp = walletManagerPointer, let wp = walletPointer else { return }

        NSLog("[MoneroCore] stopCore() called - closing wallet, self=\(Unmanaged.passUnretained(self).toOpaque())")
        let t0 = Date()
        // Store on close for cleanly-opened wallets. Tx keys created since
        // the last chunk store (up to 2000 blocks / anything sent while
        // synced) live only in memory until a store — closing without one
        // silently discards them, and tx keys are not reconstructible by a
        // rescan.
        //
        // Never let closeWallet do the store itself: WalletImpl::close(true)
        // calls wallet2::store() with no lock while wallet2's own refresh
        // thread may still be processing blocks, and serializing the hash
        // chain under a concurrent mutation crashed on wallet switch during
        // sync (SIGSEGV in do_serialize_container<deque<crypto::hash>> from
        // close(bool)). MONERO_Wallet_store goes through WalletImpl::store,
        // whose LOCK_REFRESH stops the in-flight cycle, takes both refresh
        // mutexes and stores under them. Pausing first keeps LOCK_REFRESH
        // from restarting the refresh thread when it leaves scope.
        MONERO_Wallet_pauseRefresh(wp)
        var stored = false
        if walletOpenedCleanly {
            stored = MONERO_Wallet_store(wp, cWalletPath)
            if !stored {
                let err = stringFromCString(MONERO_Wallet_errorString(wp)) ?? "unknown"
                NSLog("[MoneroCore] store before close failed: \(err)")
            }
        }
        MONERO_WalletManager_closeWallet(wmp, wp, false)
        let ms = Date().timeIntervalSince(t0) * 1000
        NSLog("[MoneroCore] closeWallet returned after %.0fms (stored=\(stored))", ms)
        walletPointer = nil
        walletOpenedCleanly = false
    }

    private func startWalletServices() {
        guard let walletPointer else { return }

        stateManager.state = .connecting(waiting: false)

        startStateManager()
        walletListener.start(walletPointer: walletPointer)
        refreshGate.syncStarted(walletPointer)
    }

    private func stopWalletServices() {
        NSLog("[MoneroCore] stopWalletServices() called, self=\(Unmanaged.passUnretained(self).toOpaque())")

        // Sync off first: a wallet change or a store that ends meanwhile
        // must not start the refresh again.
        if let walletPointer {
            refreshGate.syncPaused(walletPointer)
        }

        // Stop wallet listener first
        let t1 = Date()
        walletListener.stop()
        NSLog("[MoneroCore] walletListener.stop() took %.0fms", Date().timeIntervalSince(t1) * 1000)

        // Stop state manager (this cancels timers, drains its own queue/worker,
        // and clears the onSyncStateChanged callback).
        let t2 = Date()
        stateManager.stop()
        NSLog("[MoneroCore] stateManager.stop() took %.0fms", Date().timeIntervalSince(t2) * 1000)

        // Drain refreshQueue before stopCore() frees the wallet pointer.
        // onSyncStateChanged dispatches `self?.refresh()` onto refreshQueue,
        // which captures walletPtr at the top of the block and uses it
        // through updateBalance/fetchSubaddresses/fetchTransactions/
        // storeWallet. Without this barrier, a refresh in flight can still
        // be mid-store when closeWallet frees the pointer, and
        // WalletImpl::store's call_befor_die destructor reads the freed
        // wallet object and crashes on dereference.
        let t4 = Date()
        refreshQueue.sync(flags: .barrier) { }
        NSLog("[MoneroCore] refreshQueue barrier took %.0fms", Date().timeIntervalSince(t4) * 1000)
    }

    /// Open the wallet without connecting to daemon or starting services.
    /// After this, walletPointer is set and address derivation works.
    func prepare() {
        guard walletManagerPointer != nil else {
            logger?.error("Error: Could not get WalletManager instance.")
            return
        }

        stateManager.validateReachable()
        startCore()
    }

    /// Connect to the daemon node. Call after prepare() and address derivation.
    /// This is the slow part — network roundtrip to the remote node.
    func connectToDaemon() {
        connectDaemon()
    }

    /// Start the refresh thread and state polling. Must call connectToDaemon() first.
    func startServices() {
        // A new start turns sync on: an old pause no longer holds the services.
        _ = callerPause.end()
        startWalletServices()
    }

    func start() {
        prepare()
        connectToDaemon()
        startServices()
    }

    func stop() {
        NSLog("[MoneroCore] stop() called, self=\(Unmanaged.passUnretained(self).toOpaque())")
        stopWalletServices()
        stopCore()
    }

    func refresh(isSyncChunk: Bool = false) {
        guard let walletPtr = walletPointer else { return }
        updateBalance(walletPointer: walletPtr)
        fetchSubaddresses(walletPointer: walletPtr)
        fetchTransactions(walletPointer: walletPtr, skipNotes: isSyncChunk)
        storeWallet(walletPointer: walletPtr)
    }

    /// Restart sync state manager to check for new blocks
    /// Call this after pull-to-refresh or background wake to detect new blockchain activity
    func startSync() {
        // Only restart if wallet is open
        guard let walletPtr = walletPointer else { return }

        // The network went down and came back while sync was paused: the
        // services stopped then, and start now.
        if callerPause.end() {
            startWalletServices()
            return
        }

        // Kick off wallet2's background refresh to actually download new
        // blocks (at once, or when a wallet change in progress ends).
        refreshGate.syncStarted(walletPtr)

        // Restart the state manager to poll sync progress
        startStateManager()
    }

    /// Pause sync — stops refresh thread and state manager polling
    /// Unlike stop(), this preserves pointers and callbacks so sync can resume
    ///
    /// A wallet change or a store in progress does not undo it: it lets the
    /// refresh run again only while sync is on (`RefreshGate`). A refresh
    /// pass already running ends at its next block batch.
    func pauseSync() {
        guard let walletPtr = walletPointer else { return }
        callerPause.begin()
        refreshGate.syncPaused(walletPtr)
        stateManager.pause()
    }

    func setConnectingState(waiting: Bool) {
        stateManager.state = .connecting(waiting: waiting)
    }

    func address(index: Int) -> String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(index))) ?? ""
    }

    /// Returns the per-transaction secret key for `txId`. Combined with the
    /// recipient address, this lets anyone verify the payment with
    /// wallet2's `check_tx_key` without exposing the sender's view key.
    /// Returns nil if the wallet doesn't know the key (e.g. incoming tx,
    /// or outgoing tx from a different wallet).
    func getTxKey(txId: String) -> String? {
        guard let walletPtr = walletPointer else { return nil }
        guard let key = stringFromCString(MONERO_Wallet_getTxKey(walletPtr, txId)), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Returns the legacy 25-word Electrum-style seed from the running wallet.
    /// Works for any wallet type — wallet2 always knows the legacy seed internally.
    func getLegacySeed() -> String? {
        guard let walletPtr = walletPointer else { return nil }
        return stringFromCString(MONERO_Wallet_seed(walletPtr, ""))
    }

    /// Returns the polyseed (16 words) if the wallet was created with one.
    /// Returns nil for BIP39/legacy wallets.
    func getPolyseed() -> String? {
        guard let walletPtr = walletPointer else { return nil }
        let result = stringFromCString(MONERO_Wallet_getPolyseed(walletPtr, ""))
        // wallet2 returns empty string if not a polyseed wallet
        guard let result, !result.isEmpty else { return nil }
        return result
    }

    // MARK: - Hardware-wallet sync primitives
    //
    // The dual-cache architecture keeps a SOFTWARE/watch_only wallet
    // running 24/7 (no device needed) for incoming-tx visibility, and
    // a separate TREZOR-bound wallet that opens only during reconnect
    // sessions to run `cold_key_image_sync` against the device. The
    // session-time wallet uses the methods below.

    /// Re-establish the device transport on a hardware-bound wallet.
    /// wallet2's internal Trezor / Ledger state caches a device handle
    /// that may have gone stale (BLE drop, app suspend). Call this after
    /// the BLE bridge is back up.
    @discardableResult
    func reconnectDevice() -> Bool {
        guard let walletPtr = walletPointer else { return false }
        return MONERO_Wallet_reconnectDevice(walletPtr)
    }

    /// Backing device for the wallet's spend key. SOFTWARE means a normal
    /// seed-derived wallet or watch-only wallet; LEDGER/TREZOR mean the
    /// keys file was created with `restore_from_device` and wallet2
    /// expects a live device transport.
    func getDeviceType() -> DeviceType {
        guard let walletPtr = walletPointer else { return .software }
        return DeviceType(rawValue: MONERO_Wallet_getDeviceType(walletPtr)) ?? .software
    }

    /// Latest wallet2 status + error string. Returns ("status code",
    /// "<msg>") or nil if no wallet open. Useful right after a
    /// failed cold-sign call to capture the real wallet2 error.
    func latestStatus() -> (code: Int32, message: String)? {
        guard let walletPtr = walletPointer else { return nil }
        let status = MONERO_Wallet_status(walletPtr)
        let msg = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? ""
        return (status, msg)
    }

    /// Run wallet2's cold-key-image sync for HW-backed wallets. The
    /// wallet itself iterates its `m_transfers` and asks the device
    /// for key images, then internally imports them. Caller must
    /// ensure the bridge HTTP server is running and the device is
    /// reachable before invoking.
    /// Returns true on success — the spent/unspent counts are not
    /// surfaced to Swift since the C wrapper takes them by value
    /// (a wallet2_api_c bug we don't currently fix here).
    @discardableResult
    func coldKeyImageSync() -> Bool {
        guard let walletPtr = walletPointer else { return false }
        let result = MONERO_Wallet_coldKeyImageSync(walletPtr, 0, 0)
        // UINT64_MAX means wallet2 threw (device timeout / BLE drop /
        // protocol error). The exception leaves the wallet status
        // untouched, so this sentinel is the only failure signal.
        if result == UInt64.max {
            NSLog("[MoneroCore] coldKeyImageSync threw inside wallet2 — device did not complete key-image sync")
            return false
        }
        // wallet2 returns the number of imported key images on
        // success, 0 if nothing imported (which is also valid for
        // a wallet with no transfers). Treat any non-error status
        // as success.
        let status = MONERO_Wallet_status(walletPtr)
        if status != 0 {
            return false
        }
        return true
    }

    enum DeviceType: Int32 {
        case software = 0
        case ledger = 1
        case trezor = 2
    }

    /// Add a new subaddress to the wallet
    /// - Parameter label: Optional label for the subaddress
    /// - Returns: The index and address of the newly created subaddress
    ///
    /// It does not wait for a refresh pass in flight, and a quit loses the
    /// row: use `addSubaddressAndStore`.
    func addSubaddress(label: String = "") -> (index: Int, address: String)? {
        guard let walletPtr = walletPointer else { return nil }

        // Pause refresh thread — wallet2 isn't thread-safe for addSubaddress
        // while refresh is running, causing an abort in the C++ layer. The
        // gate starts it again only while sync is on.
        refreshGate.hold(walletPtr)
        defer { refreshGate.release(walletPtr) }

        return appendSubaddress(walletPtr, label: label)
    }

    /// How long a subaddress change (`addSubaddressAndStore`,
    /// `setSubaddressLabelAndStore`) waits to start: for its turn on
    /// `refreshQueue`, then for a wallet2 refresh pass in flight to end
    /// (`settleRefresh`). With a node that answers, a pass ends at its next
    /// block batch.
    static let subaddressChangeWait: TimeInterval = 5
    /// How long a subaddress change waits for the wallet-file store after
    /// the change. The refresh is at rest then, so the store only writes.
    static let subaddressStoreWait: TimeInterval = 1.5

    /// `addSubaddress`, and the wallet file is stored. wallet2 keeps the
    /// subaddress rows in the wallet file, which it otherwise writes only at
    /// the next sync store or at close: a quit or a crash before then forgets
    /// the row, and the next new subaddress gets the same index and address.
    ///
    /// The add waits for a refresh pass in flight (`changeAndStore`), so it
    /// never changes wallet2's subaddress table while a scan reads it. If
    /// the store takes longer than `storeWait`, this returns first and the
    /// store lands later. Until then the kit's database lists the row, and
    /// `Kit` lists it in wallet2 again at the next open
    /// (`Kit.relistStoredSubaddresses`). Call it on the kit's lifecycle
    /// queue.
    /// - Throws: `walletNotInitialized` with no wallet open;
    ///   `walletStatusError` when wallet2 added no row, when the store failed
    ///   within `storeWait`, or ("The wallet is busy") when the add did not
    ///   start within `addWait` (it then never adds a row).
    func addSubaddressAndStore(
        label: String = "",
        addWait: TimeInterval = MoneroCore.subaddressChangeWait,
        storeWait: TimeInterval = MoneroCore.subaddressStoreWait
    ) throws -> (index: Int, address: String) {
        try changeAndStore(changeWait: addWait, storeWait: storeWait) { core, walletPtr -> Result<(index: Int, address: String), Error> in
            guard let created = core.appendSubaddress(walletPtr, label: label) else {
                return .failure(MoneroCoreError.walletStatusError("wallet2 added no subaddress"))
            }
            return .success(created)
        }
    }

    /// Sets the label of the subaddress at `index` and stores the wallet
    /// file, the same way as `addSubaddressAndStore`: the caller waits at
    /// most `labelWait` and `storeWait`, never for a whole refresh. Call it
    /// on the kit's lifecycle queue.
    /// - Throws: `walletNotInitialized` with no wallet open;
    ///   `walletStatusError` when the wallet lists no row at `index`, when
    ///   wallet2 did not take the label, when the store failed within
    ///   `storeWait`, or ("The wallet is busy") when the change did not start
    ///   within `labelWait` (it then never changes the label).
    func setSubaddressLabelAndStore(
        index: Int,
        label: String,
        labelWait: TimeInterval = MoneroCore.subaddressChangeWait,
        storeWait: TimeInterval = MoneroCore.subaddressStoreWait
    ) throws {
        try changeAndStore(changeWait: labelWait, storeWait: storeWait) { core, walletPtr -> Result<Void, Error> in
            guard index >= 0, index < Int(MONERO_Wallet_numSubaddresses(walletPtr, core.account)) else {
                return .failure(MoneroCoreError.walletStatusError("No subaddress at this index"))
            }
            MONERO_Wallet_setSubaddressLabel(walletPtr, core.account, UInt32(index), label)
            // The label read back, not the wallet status: other threads
            // write the status (see `addSubaddressRows`).
            guard stringFromCString(MONERO_Wallet_getSubaddressLabel(walletPtr, core.account, UInt32(index))) == label else {
                let errorStr = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "unknown"
                NSLog("[MoneroCore] setSubaddressLabel index=\(index) failed: \(errorStr)")
                return .failure(MoneroCoreError.walletStatusError(errorStr))
            }
            core.fetchSubaddresses(walletPointer: walletPtr)
            return .success(())
        }
    }

    /// Runs `change` on `refreshQueue` with wallet2's refresh at rest, then
    /// stores the wallet file.
    ///
    /// The block holds the refresh (`refreshGate`), so no new pass starts,
    /// and waits for a pass in flight to end (`settleRefresh`) before the
    /// change. A pass reads and grows wallet2's subaddress table from its
    /// threads with no lock, and `pauseRefresh` alone does not wait for it.
    /// The store after the change then finds the refresh at rest. When the
    /// block ends, the refresh runs again only while sync is on: a change
    /// while sync is paused (Trusted Locations, background) never starts it,
    /// and so never calls the node. The next `startSync` does.
    ///
    /// The caller waits up to `changeWait` for the change, and the block
    /// then never runs a change it did not start by that time. After the
    /// change, the caller waits up to `storeWait` for the store; a store
    /// that takes longer lands later.
    private func changeAndStore<Value>(
        changeWait: TimeInterval,
        storeWait: TimeInterval,
        _ change: @escaping (MoneroCore, UnsafeMutableRawPointer) -> Result<Value, Error>
    ) throws -> Value {
        let job = SubaddressStoreJob<Value>()
        subaddressStores.begin()
        let work = DispatchWorkItem(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
            guard let self else {
                job.finishChange(.failure(MoneroCoreError.walletNotInitialized))
                return
            }
            defer { subaddressStores.end() }
            guard let walletPtr = walletPointer else {
                job.finishChange(.failure(MoneroCoreError.walletNotInitialized))
                return
            }
            refreshGate.hold(walletPtr)
            defer { refreshGate.release(walletPtr) }
            settleRefresh(walletPtr)
            guard job.start() else { return }
            let result = change(self, walletPtr)
            job.finishChange(result)
            guard case .success = result else { return }
            let started = Date()
            do {
                try storeNow(walletPtr)
                job.finishStore(nil)
            } catch {
                job.finishStore(error)
            }
            let waited = Date().timeIntervalSince(started)
            if waited > storeWait {
                NSLog("[MoneroCore] store after a subaddress change landed after %.1f s", waited)
            }
        }
        refreshQueue.async(execute: work)

        guard let changed = job.waitForChange(timeout: changeWait) else {
            NSLog("[MoneroCore] subaddress change: the wallet stayed busy for %.1f s, changed nothing", changeWait)
            throw MoneroCoreError.walletStatusError("The wallet is busy")
        }
        let value = try changed.get()
        switch job.waitForStore(timeout: storeWait) {
        case .none:
            NSLog("[MoneroCore] subaddress change returned before its store")
        case let .some(error?):
            throw error
        case .some(.none):
            break
        }
        return value
    }

    /// Waits until a wallet2 refresh pass in flight has ended. Call it on
    /// `refreshQueue` with the refresh held (`refreshGate.hold`): then no
    /// new pass starts until the release.
    ///
    /// `pauseRefresh` keeps new passes from starting and ends a running one
    /// at its next block batch, but does not wait for it. The pass's threads
    /// read wallet2's subaddress table (`m_subaddresses`) and grow it and
    /// `m_subaddress_labels` (`expand_subaddresses`) with no lock, and
    /// `add_subaddress` changes the same containers: a change during a scan
    /// is a data race, a crash or a missed output. A TestFlight build
    /// crashed on a new subaddress during sync (app 24ecdfc).
    ///
    /// The C API's only wait for a pass is the LOCK_REFRESH in
    /// `WalletImpl::store`, which takes both refresh mutexes, so this stores
    /// the wallet file. With a node that does not answer, the pass ends only
    /// when its daemon call does: up to 20 s for a connect, longer for a
    /// reply that stops midway. A wallet that did not open cleanly is never
    /// stored (see `stopCore`); for it this does not wait.
    private func settleRefresh(_ walletPtr: UnsafeMutableRawPointer) {
        guard walletOpenedCleanly else { return }
        let started = Date()
        if !MONERO_Wallet_store(walletPtr, cWalletPath) {
            let errorStr = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "unknown"
            NSLog("[MoneroCore] store before a subaddress change failed: \(errorStr)")
        }
        let waited = Date().timeIntervalSince(started)
        if waited > 1 {
            NSLog("[MoneroCore] a refresh pass in flight ended after %.1f s", waited)
        }
    }

    /// Subaddress changes that are queued or running on `refreshQueue`.
    private let subaddressStores = PendingCount()

    /// True while a subaddress change (`changeAndStore`) is queued, waits
    /// for a refresh pass, or stores.
    var subaddressStorePending: Bool { subaddressStores.value > 0 }

    /// Waits until each subaddress change queued so far has ended. Not on
    /// `refreshQueue`.
    func waitForSubaddressStores() {
        guard subaddressStorePending else { return }
        refreshQueue.sync {}
    }

    /// The index of `address` among this account's subaddresses, from 1 to
    /// below `limit`, or nil. Each address is derived from the wallet's keys,
    /// as wallet2 fills its own subaddress table, so it also finds a
    /// subaddress that the wallet does not list: a wallet restored from its
    /// seed lists the rows only up to the last one that received funds.
    func subaddressIndex(of address: String, below limit: Int) -> Int? {
        guard let walletPtr = walletPointer, limit > 1 else { return nil }
        for index in 1 ..< limit {
            if stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(index))) == address {
                return index
            }
        }
        return nil
    }

    /// The number of subaddress rows the wallet lists in this account.
    func subaddressCount() -> Int {
        guard let walletPtr = walletPointer else { return 0 }
        return Int(MONERO_Wallet_numSubaddresses(walletPtr, account))
    }

    /// Lists the subaddress rows up to `index` (the rows added before it get
    /// no label) and stores the wallet file. False, with no change, when
    /// `address` is not this wallet's subaddress at `index`. The rows are
    /// added with the refresh at rest (`settleRefresh`), and the refresh
    /// runs again after it only while sync is on: never before the daemon
    /// connect or while sync is paused.
    func listSubaddressAndStore(index: Int, address: String) throws -> Bool {
        try refreshQueue.sync {
            guard let walletPtr = walletPointer else { throw MoneroCoreError.walletNotInitialized }
            guard index >= 1, !NullKeyAddress.isNullKey(address),
                  stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(index))) == address
            else { return false }
            guard Int(MONERO_Wallet_numSubaddresses(walletPtr, account)) <= index else {
                fetchSubaddresses(walletPointer: walletPtr)
                return true
            }
            refreshGate.hold(walletPtr)
            defer { refreshGate.release(walletPtr) }
            settleRefresh(walletPtr)
            guard addSubaddressRows(walletPtr, upTo: index + 1, label: "") else {
                throw MoneroCoreError.walletStatusError("wallet2 added no subaddress")
            }
            fetchSubaddresses(walletPointer: walletPtr)
            NSLog("[MoneroCore] listed subaddress rows through index=\(index)")
            try storeNow(walletPtr)
            return true
        }
    }

    /// Adds the next subaddress row. Call with refresh paused.
    private func appendSubaddress(_ walletPtr: UnsafeMutableRawPointer, label: String) -> (index: Int, address: String)? {
        // The new index is the count before (0-indexed)
        let newIndex = Int(MONERO_Wallet_numSubaddresses(walletPtr, account))
        guard addSubaddressRows(walletPtr, upTo: newIndex + 1, label: label),
              let newAddress = stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(newIndex)))
        else {
            return nil
        }

        // Refresh subaddresses list
        fetchSubaddresses(walletPointer: walletPtr)

        NSLog("[MoneroCore] addSubaddress: created index=\(newIndex)")

        return (index: newIndex, address: newAddress)
    }

    /// Adds subaddress rows until the account has `count` of them. Call with
    /// refresh paused. The row count tells whether wallet2 added a row, not
    /// its status: the status is one field for the whole wallet, and other
    /// threads write it. A refresh still in flight and the sync's daemon
    /// height poll write an error each time the node does not answer. An
    /// error that lands just after the add made a subaddress that was added
    /// look failed, and the username flow said "The wallet changed".
    private func addSubaddressRows(_ walletPtr: UnsafeMutableRawPointer, upTo count: Int, label: String) -> Bool {
        while true {
            let before = Int(MONERO_Wallet_numSubaddresses(walletPtr, account))
            if before >= count { return true }
            MONERO_Wallet_addSubaddress(walletPtr, account, label)
            guard Int(MONERO_Wallet_numSubaddresses(walletPtr, account)) == before + 1 else {
                let errorStr = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "unknown"
                NSLog("[MoneroCore] addSubaddress added no row: \(errorStr)")
                return false
            }
        }
    }

    /// Writes the wallet file now, as `commit` does. A wallet that did not
    /// open cleanly is never stored (see `stopCore`).
    private func storeNow(_ walletPtr: UnsafeMutableRawPointer) throws {
        guard walletOpenedCleanly else { return }
        guard MONERO_Wallet_store(walletPtr, cWalletPath) else {
            let errorStr = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "unknown"
            NSLog("[MoneroCore] store after a new subaddress failed: \(errorStr)")
            throw MoneroCoreError.walletStatusError(errorStr)
        }
    }

    /// Read the label for a subaddress directly from wallet2's in-memory state
    /// (sourced from the `.keys` cache on disk).
    func getSubaddressLabel(index: Int) -> String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_getSubaddressLabel(walletPtr, account, UInt32(index))) ?? ""
    }

    /// Signs `message` with the spend key of `subaddress` (wallet2 SigV2,
    /// spend mode). The rules are in `Kit.signMessage(_:subaddress:)`.
    func signMessage(_ message: String, subaddress: String) throws -> String {
        try MessageSigner.checkMessage(message)
        guard let walletPtr = walletPointer else {
            throw SignMessageError.walletNotOpen
        }
        return try MessageSigner.sign(message, subaddress: subaddress, walletPointer: walletPtr)
    }

    /// Signs a transaction and returns it unbroadcast, with its final txids.
    func prepareSend(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String? = nil) throws -> PreparedTransaction {
        guard let walletPtr = walletPointer else {
            NSLog("[MoneroCore] send: walletPointer is nil")
            throw MoneroCoreError.walletNotInitialized
        }

        // Recipient prefix + exact amount + timestamp is a strong selector
        // against a chain explorer, and the unified log is readable via
        // sysdiagnose, a tethered Mac, or MDM. Same reasoning as the primary
        // address and balance logs removed above — keep it out of Release.
        #if DEBUG
        NSLog("[MoneroCore] send: creating transaction to \(address.prefix(16))..., amount=\(amount.value), priority=\(priority.rawValue)")
        #endif
        let cAddress = (address as NSString).utf8String
        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", amount.value, 0, Int32(priority.rawValue), account, "", "")

        guard let txPtr = pendingTxPtr else {
            let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown transaction creation error"
            NSLog("[MoneroCore] send: createTransaction returned nil, error='\(error)'")
            throw MoneroCoreError.transactionSendFailed(error)
        }

        let status = MONERO_PendingTransaction_status(txPtr)
        let txError = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? ""
        NSLog("[MoneroCore] send: transaction created, status=\(status), error='\(txError)'")

        guard status == 0 else {
            NSLog("[MoneroCore] send: transaction status non-zero, failing")
            throw MoneroCoreError.match(txError) ?? MoneroCoreError.transactionSendFailed(txError)
        }

        let txids = (stringFromCString(MONERO_PendingTransaction_txid(txPtr, "|")) ?? "")
            .split(separator: "|").map(String.init).filter { !$0.isEmpty }
        guard !txids.isEmpty else {
            NSLog("[MoneroCore] send: signed transaction has no txid, failing")
            throw MoneroCoreError.transactionSendFailed("Signed transaction has no txid")
        }
        return PreparedTransaction(
            txids: txids,
            amount: MONERO_PendingTransaction_amount(txPtr),
            fee: MONERO_PendingTransaction_fee(txPtr),
            address: address,
            pointer: txPtr,
            walletGeneration: walletGeneration,
            memo: memo
        )
    }

    /// The transaction from `prepareSend` can still be committed: the
    /// wallet open it was signed in is still open, and it was not sent.
    func isPrepared(_ prepared: PreparedTransaction) -> Bool {
        walletPointer != nil && prepared.walletGeneration == walletGeneration && !prepared.isUsed
    }

    /// Broadcasts a transaction from `prepareSend`. Throws
    /// `walletNotInitialized`, with nothing sent, when the wallet it was
    /// signed in has closed, and `transactionSendFailed` when it was
    /// committed before.
    func commit(_ prepared: PreparedTransaction) throws {
        guard let walletPtr = walletPointer, prepared.walletGeneration == walletGeneration else {
            NSLog("[MoneroCore] send: the wallet closed after signing, nothing sent")
            throw MoneroCoreError.walletNotInitialized
        }
        guard !prepared.isUsed else {
            throw MoneroCoreError.transactionSendFailed("Transaction already sent")
        }
        prepared.isUsed = true
        let txPtr = prepared.pointer

        if let memo = prepared.memo, let txId = prepared.txids.first {
            MONERO_Wallet_setUserNote(walletPtr, (txId as NSString).utf8String, (memo as NSString).utf8String)
        }

        NSLog("[MoneroCore] send: committing transaction...")
        guard MONERO_PendingTransaction_commit(txPtr, "", false) else {
            let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
            NSLog("[MoneroCore] send: commit failed, error='\(error)'")
            throw MoneroCoreError.transactionCommitFailed(error)
        }
        NSLog("[MoneroCore] send: transaction committed successfully")

        // Pull the fresh outgoing tx into storage immediately so any
        // caller that reads `kit.transactions(...)` right after `send`
        // returns sees it. `startStateManager()` does refresh on its
        // own polling thread, but the dispatch is async — by the time
        // it runs, the hardware-session driver has already snapshotted
        // tx history (to persist the outgoing entry while the FULL
        // wallet is still open). Without this synchronous fetch the
        // snapshot is missing the just-sent tx and the home screen
        // shows the change UTXO as a Received row until the next
        // refresh tick.
        fetchTransactions(walletPointer: walletPtr)
        updateBalance(walletPointer: walletPtr)

        // Persist the wallet cache right away: the commit just minted this
        // transaction's tx key, which exists nowhere but in-memory wallet2
        // state until a store. A crash/kill before the next chunk store
        // would lose it permanently.
        storeWallet(walletPointer: walletPtr)

        startStateManager()
    }

    @discardableResult
    func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String? = nil) throws -> PreparedTransaction {
        let prepared = try prepareSend(to: address, amount: amount, priority: priority, memo: memo)
        try commit(prepared)
        return prepared
    }

    func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        guard let walletPtr = walletPointer else {
            NSLog("[MoneroCore] estimateFee: walletPointer is nil, self=\(Unmanaged.passUnretained(self).toOpaque())")
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let cAmount = ("\(amount.value)" as NSString).utf8String
        #if DEBUG
        NSLog("[MoneroCore] estimateFee: calling with amount=\(amount.value), priority=\(priority.rawValue)")
        #endif
        let fee = MONERO_Wallet_estimateTransactionFee(walletPtr, cAddress, "", cAmount, "", Int32(priority.rawValue))
        let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? ""
        NSLog("[MoneroCore] estimateFee: fee=\(fee), error='\(error)'")
        if !error.isEmpty, error != "No error" {
            throw MoneroCoreError.match(error) ?? MoneroCoreError.transactionEstimationFailed(error)
        }
        return fee
    }

    struct Transaction {
        public enum Direction: Int32 {
            case `in` = 0
            case out = 1
        }

        let direction: Direction
        let isPending: Bool
        let isFailed: Bool
        let amount: Int64
        let fee: UInt64
        let subaddrIndices: [Int]
        let subaddrAccount: UInt32
        let blockHeight: UInt64
        let confirmations: UInt64
        let hash: String
        let timestamp: Date
        let note: String?
        var transfers: [Transfer]
    }

    struct SubAddress {
        let address: String
        let index: Int
        let label: String
    }

    struct Balance: Equatable {
        // CRITICAL: Use UInt64 to prevent integer overflow on 32-bit systems
        // or for very large balances (> 2^63 piconero = ~9.2 million XMR)
        let all: UInt64
        let unlocked: UInt64

        static func == (lhs: Balance, rhs: Balance) -> Bool {
            lhs.all == rhs.all && lhs.unlocked == rhs.unlocked
        }
    }
}

extension MoneroCore {
    private static func resolveMnemonic(mnemonic: MoneroWallet) throws -> (String, String) {
        let resolvedSeedPhrase: String
        let resolvedPassphrase: String

        switch mnemonic {
        case let .bip39(mnemonic, passphrase):
            resolvedSeedPhrase = try legacySeedFromBip39(mnemonic: mnemonic, passphrase: passphrase)
            resolvedPassphrase = ""

        case let .legacy(mnemonic, passphrase):
            // NFC, as in createWalletFromCredentials.
            resolvedSeedPhrase = mnemonic.joined(separator: " ").precomposedStringWithCanonicalMapping
            resolvedPassphrase = passphrase

        case let .polyseed(mnemonic, passphrase):
            resolvedSeedPhrase = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case .watch:
            resolvedSeedPhrase = ""
            resolvedPassphrase = ""

        case .trezor:
            resolvedSeedPhrase = ""
            resolvedPassphrase = ""
        }

        return (resolvedSeedPhrase, resolvedPassphrase)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MONERO_Wallet_addressValid((address as NSString).utf8String, networkType.rawValue)
    }

    static func isValid(viewKey: String, address: String, isViewKey: Bool, networkType: NetworkType) -> Bool {
        MONERO_Wallet_keyValid((viewKey as NSString).utf8String, (address as NSString).utf8String, isViewKey, networkType.rawValue)
    }

    static func key(wallet: MoneroWallet, privateKey: Bool = false, spendKey: Bool = false) throws -> String? {
        switch wallet {
        case .bip39, .legacy, .polyseed:
            let (resolvedSeedPhrase, resolvedPassphrase) = try resolveMnemonic(mnemonic: wallet)

            guard !resolvedSeedPhrase.isEmpty else {
                return nil
            }

            let cSeed = strdup((resolvedSeedPhrase as NSString).utf8String)
            let cPassphrase = strdup((resolvedPassphrase as NSString).utf8String)
            let keyPtr = MONERO_Wallet_generateKey(cSeed, cPassphrase, privateKey, spendKey)

            return stringFromCString(keyPtr)

        case let .watch(_, viewKey):
            if privateKey, !spendKey {
                return viewKey
            } else {
                return ""
            }

        case .trezor:
            // Trezor wallet keys live on-device — never returned from the
            // host process. Caller should use Kit.secretViewKey or read the
            // primary address from wallet2 once the device session populates
            // them.
            return nil
        }
    }

    static func address(wallet: MoneroWallet, account: UInt32, index: UInt32, networkType: NetworkType) throws -> String {
        switch wallet {
        case .bip39, .legacy, .polyseed:
            let (resolvedSeedPhrase, resolvedPassphrase) = try resolveMnemonic(mnemonic: wallet)

            let testnet = networkType != .mainnet
            let cAddressString = MONERO_Wallet_generateAddress(resolvedSeedPhrase, resolvedPassphrase, account, index, testnet)

            return stringFromCString(cAddressString) ?? ""

        case let .watch(address, _):
            if account == 0, index == 0 {
                return address
            } else {
                return ""
            }

        case .trezor:
            // Address derivation requires a live device session. Empty until
            // wallet2 has the device handshake to ask for it.
            return ""
        }
    }
}

protocol MoneroCoreDelegate: AnyObject {
    func balanceDidChange(balance: MoneroCore.Balance)
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress])
    func walletStateDidChange(state: WalletState)
    func restoreHeightUpdated(height: UInt64)
}

/// The hand-off between a subaddress change (`MoneroCore.changeAndStore`)
/// and its block on the refresh queue. The caller can stop waiting for a
/// change that has not started: that block then changes nothing.
final class SubaddressStoreJob<Value> {
    private enum Phase { case queued, running, abandoned }

    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let stored = DispatchSemaphore(value: 0)
    private var phase = Phase.queued
    private var changeResult: Result<Value, Error>?
    private var storeError: Error?

    /// The block calls it right before the change. False when the caller
    /// stopped waiting.
    func start() -> Bool {
        lock.withLock {
            guard phase == .queued else { return false }
            phase = .running
            return true
        }
    }

    func finishChange(_ result: Result<Value, Error>) {
        lock.withLock { changeResult = result }
        changed.signal()
    }

    func finishStore(_ error: Error?) {
        lock.withLock { storeError = error }
        stored.signal()
    }

    /// The change's result, or nil when the change did not start within
    /// `timeout`. A change that started finishes in a moment.
    func waitForChange(timeout: TimeInterval) -> Result<Value, Error>? {
        if changed.wait(timeout: .now() + timeout) == .timedOut {
            let abandoned: Bool = lock.withLock {
                guard phase == .queued else { return false }
                phase = .abandoned
                return true
            }
            if abandoned { return nil }
            changed.wait()
        }
        return lock.withLock { changeResult }
    }

    /// `.some(error)` when the store ended within `timeout` (`.some(nil)`:
    /// stored), nil when it still runs.
    func waitForStore(timeout: TimeInterval) -> Error?? {
        guard stored.wait(timeout: .now() + timeout) == .success else { return nil }
        return .some(lock.withLock { storeError })
    }
}

/// Who runs wallet2's refresh thread. Sync turns it on (the services'
/// start, `startSync`) and off (`pauseSync`, a stop). A wallet change or a
/// store holds it off while it runs, and the last hold to end turns it on
/// again only while sync is on. So a new subaddress, a rename or a store
/// never starts a refresh, and never calls the node, while sync is paused.
///
/// `WalletImpl::startRefresh` wakes the refresh thread at once, and its pass
/// starts with a daemon call. wallet2 keeps one flag for both owners, so
/// without the gate each subaddress change ended with a start, also while
/// sync was paused outside a trusted location.
final class RefreshGate {
    private let lock = NSLock()
    private var syncOn = false
    private var holds = 0
    private let startRefresh: (UnsafeMutableRawPointer) -> Void
    private let pauseRefresh: (UnsafeMutableRawPointer) -> Void

    init(
        startRefresh: @escaping (UnsafeMutableRawPointer) -> Void = { MONERO_Wallet_startRefresh($0) },
        pauseRefresh: @escaping (UnsafeMutableRawPointer) -> Void = { MONERO_Wallet_pauseRefresh($0) }
    ) {
        self.startRefresh = startRefresh
        self.pauseRefresh = pauseRefresh
    }

    var isSyncOn: Bool { lock.withLock { syncOn } }

    /// Sync on: the refresh runs now, or when the last hold ends.
    func syncStarted(_ wallet: UnsafeMutableRawPointer) {
        lock.withLock {
            syncOn = true
            if holds == 0 { startRefresh(wallet) }
        }
    }

    /// Sync off: the refresh stops, and no hold that ends starts it again.
    func syncPaused(_ wallet: UnsafeMutableRawPointer) {
        lock.withLock {
            syncOn = false
            pauseRefresh(wallet)
        }
    }

    /// Keeps the refresh off until `release`. Each hold needs one release.
    func hold(_ wallet: UnsafeMutableRawPointer) {
        lock.withLock {
            holds += 1
            pauseRefresh(wallet)
        }
    }

    func release(_ wallet: UnsafeMutableRawPointer) {
        lock.withLock {
            holds -= 1
            if holds == 0, syncOn { startRefresh(wallet) }
        }
    }
}

/// A sync pause of the kit's caller, and whether the wallet services wait for
/// its end. The pause and the start run on the kit's lifecycle queue, the
/// network's return on the state manager's queue.
final class CallerPause {
    private let lock = NSLock()
    private var paused = false
    private var servicesDeferred = false

    func begin() { lock.withLock { paused = true } }

    /// True, and the services wait for `end`, while paused.
    func deferServices() -> Bool {
        lock.withLock {
            if paused { servicesDeferred = true }
            return paused
        }
    }

    /// The services stopped: they no longer wait for the end of the pause.
    func servicesStopped() { lock.withLock { servicesDeferred = false } }

    /// Ends the pause. True when the services waited for it.
    func end() -> Bool {
        lock.withLock {
            defer { paused = false; servicesDeferred = false }
            return servicesDeferred
        }
    }
}

/// A count that several threads raise and lower.
final class PendingCount {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func begin() { lock.withLock { count += 1 } }
    func end() { lock.withLock { count -= 1 } }
}
