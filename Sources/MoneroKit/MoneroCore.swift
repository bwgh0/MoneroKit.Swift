import CMonero
import Combine
import Foundation
import HsToolKit

class MoneroCore {
    weak var delegate: MoneroCoreDelegate?

    private let globalEventQueue = DispatchQueue.global(qos: .userInteractive)

    private var wallet: MoneroWallet
    private var stateManager: SyncStateManager
    private var walletListener: WalletListener
    private var networkType: NetworkType = .mainnet
    private var walletManagerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private let logger: Logger?
    private let moneroCoreLogLevel: Int32? // 0..4
    private var restoreHeight: UInt64 = 0
    var account: UInt32
    var node: Node

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

    private var balance: Balance = .init(all: 0, unlocked: 0) {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                if oldValue != balance {
                    delegate?.balanceDidChange(balance: balance)
                }
            }
        }
    }

    var state: WalletState {
        stateManager.state
    }

    var blockHeights: (UInt64, UInt64)? {
        stateManager.blockHeights
    }

    /// Internal accessor for wallet pointer (used by LightWalletCore)
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
        stateManager = SyncStateManager(logger: logger, restoreHeight: restoreHeight, reachabilityManager: reachabilityManager, isLightWallet: node.isLightWallet)
        walletListener = WalletListener()
        walletManagerPointer = MONERO_WalletManagerFactory_getWalletManager()

        stateManager.onSyncStateChanged = { [weak self] in
            self?.onSyncStateChanged()
        }

        walletListener.onNewTransaction = { [weak self] in
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
        } else {
            switch wallet {
            case let .bip39(mnemonic, passphrase):
                let legacySeed = try legacySeedFromBip39(mnemonic: mnemonic, passphrase: passphrase)

                recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    (legacySeed as NSString).utf8String,
                    networkType.rawValue,
                    restoreHeight,
                    1,
                    ""
                )

            case let .legacy(mnemonic, passphrase):
                let seed = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping

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
            }
        }

        guard let walletPtr = recoveredWalletPtr else {
            let errorCStr = MONERO_WalletManager_errorString(walletManagerPointer)
            let msg = stringFromCString(errorCStr) ?? "Unknown recovery error"
            NSLog("[MoneroCore] ERROR recovering wallet: \(msg)")
            logger?.error("Error recovering wallet: \(msg)")
            return
        }

        let cDaemonAddress = strdup((node.url.absoluteString as NSString).utf8String)
        let cDaemonLogin = strdup(((node.login ?? "") as NSString).utf8String)
        let cDaemonPassword = strdup(((node.password ?? "") as NSString).utf8String)
        let useSSL = node.url.scheme?.lowercased() == "https"
        NSLog("[MoneroCore] Initializing wallet with daemon: \(node.url.absoluteString), useSSL=\(useSSL), lightWallet=\(node.isLightWallet)")
        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, cDaemonLogin, cDaemonPassword, useSSL, node.isLightWallet, "")
        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            NSLog("[MoneroCore] ERROR initializing wallet with daemon: \(msg)")
            logger?.error("Error initializing wallet with daemon: \(msg)")
            return
        }
        NSLog("[MoneroCore] Wallet initialized successfully with daemon, self=\(Unmanaged.passUnretained(self).toOpaque())")

        // Light wallet servers are always trusted by design
        MONERO_Wallet_setTrustedDaemon(walletPtr, node.isLightWallet || node.isTrusted)

        // For light wallet mode, call lightWalletLogin to authenticate with the LWS
        // This is REQUIRED for wallet2 to fetch outputs via /get_unspent_outs
        print("[MoneroCore] DEBUG: node.isLightWallet = \(node.isLightWallet)")
        if node.isLightWallet {
            print("[MoneroCore] DEBUG: Attempting light wallet login...")
            var isNewWallet: Bool = false
            let loginSuccess = MONERO_Wallet_lightWalletLogin(walletPtr, &isNewWallet)
            print("[MoneroCore] DEBUG: loginSuccess = \(loginSuccess)")
            if loginSuccess {
                NSLog("[MoneroCore] Light wallet login successful, isNewWallet=\(isNewWallet)")
                print("[MoneroCore] Light wallet login successful, isNewWallet=\(isNewWallet)")

                // CRITICAL FIX: Start background refresh to fetch outputs from LWS
                // lightWalletLogin() only authenticates - it does NOT fetch outputs
                // Note: synchronous refresh() doesn't work in light wallet mode,
                // but startRefresh() (background thread) does call /get_unspent_outs
                NSLog("[MoneroCore] Starting background refresh to fetch outputs from LWS...")
                print("[MoneroCore] Starting background refresh...")
                MONERO_Wallet_startRefresh(walletPtr)
                NSLog("[MoneroCore] Initialization loop skipped (FIX APPLIED)")
                print("[MoneroCore] startRefresh called")

                // Poll for wallet to become synchronized and balance to appear (max 15 seconds)
                // DEADLOCK FIX: Don't block initialization waiting for balance.
                // Let the background refresh finish asynchronously and update via delegates.
                /*
                var attempts = 0
                let maxAttempts = 30  // 30 * 0.5s = 15 seconds
                while attempts < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.5)
                    attempts += 1

                    let isSynced = MONERO_Wallet_synchronized(walletPtr)
                    let status = MONERO_Wallet_status(walletPtr)
                    let balance = MONERO_Wallet_balance(walletPtr, account)
                    let walletHeight = MONERO_Wallet_blockChainHeight(walletPtr)
                    let daemonHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)

                    if attempts % 4 == 0 || balance > 0 {  // Log every 2 seconds or when balance found
                        NSLog("[MoneroCore] LWS poll \(attempts): synced=\(isSynced), status=\(status), balance=\(balance), walletH=\(walletHeight), daemonH=\(daemonHeight)")
                    }

                    if balance > 0 {
                        let unlocked = MONERO_Wallet_unlockedBalance(walletPtr, account)
                        NSLog("[MoneroCore] Light wallet outputs fetched after \(attempts * 500)ms, balance=\(balance), unlocked=\(unlocked)")
                        break
                    }

                    if attempts == maxAttempts {
                        let errorCStr = MONERO_Wallet_errorString(walletPtr)
                        let errMsg = stringFromCString(errorCStr) ?? "none"
                        NSLog("[MoneroCore] Light wallet balance still 0 after \(maxAttempts * 500)ms, error=\(errMsg)")
                    }
                }
                */
            } else {
                let errorCStr = MONERO_Wallet_errorString(walletPtr)
                let msg = stringFromCString(errorCStr) ?? "Unknown light wallet login error"
                NSLog("[MoneroCore] WARNING: Light wallet login failed: \(msg)")
                // Continue anyway - the wallet might still work for some operations
            }
        }

        walletPointer = recoveredWalletPtr
        wallet.clear()

        // Log wallet address for debugging
        if let addr = stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0)) {
            NSLog("[MoneroCore] Wallet primary address: \(addr)")
        }
    }

    private func onSyncStateChanged() {
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.walletStateDidChange(state: state)
        }

        switch state {
        case .connecting, .notSynced: ()

        case .synced:
            stateManager.stop()
            refresh()
            stateManager.walletStored()

        case .syncing:
            if stateManager.chunkOfBlocksSynced {
                refresh()
                stateManager.walletStored()
            }

        case let .idle(daemonReachable):
            daemonReachable ? startWalletServices() : stopWalletServices()
        }
    }

    private func storeWallet(walletPointer: UnsafeMutableRawPointer) {
        _ = MONERO_Wallet_store(walletPointer, cWalletPath)
    }

    private func updateBalance(walletPointer: UnsafeMutableRawPointer) {
        let allBalance = MONERO_Wallet_balance(walletPointer, account)
        let unlocked = MONERO_Wallet_unlockedBalance(walletPointer, account)
        NSLog("[MoneroCore] updateBalance: all=\(allBalance), unlocked=\(unlocked), isLightWallet=\(node.isLightWallet)")
        balance = Balance(all: allBalance, unlocked: unlocked)
    }

    private func fetchSubaddresses(walletPointer: UnsafeMutableRawPointer) {
        var fetchedAddresses: [SubAddress] = []
        let count = MONERO_Wallet_numSubaddresses(walletPointer, account)

        for i in 0 ..< count {
            if let address = stringFromCString(MONERO_Wallet_address(walletPointer, UInt64(account), UInt64(i))) {
                fetchedAddresses.append(.init(address: address, index: i))
            }
        }

        subAddresses = fetchedAddresses
    }

    private func fetchTransactions(walletPointer: UnsafeMutableRawPointer) {
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

            var note: String? = stringFromCString(MONERO_Wallet_getUserNote(walletPointer, hash))
            if let _note = note, _note.isEmpty { note = nil }

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

        if hasUnconfirmedTransactions, biggestConfirmations < Kit.confirmationsThreshold {
            walletListener.setLockedBalanceHeight(height: stateManager.walletHeight - biggestConfirmations)
        }
    }

    private func startCore() {
        guard walletPointer == nil else { return }
        do {
            try openWallet()
        } catch {
            stateManager.state = .notSynced(error: .startError(error.localizedDescription))
        }
    }

    private func stopCore() {
        guard let wmp = walletManagerPointer, let wp = walletPointer else { return }

        NSLog("[MoneroCore] stopCore() called - closing wallet, self=\(Unmanaged.passUnretained(self).toOpaque())")
        MONERO_WalletManager_closeWallet(wmp, wp, false)
        walletPointer = nil
    }

    private func startWalletServices() {
        guard let walletPointer else { return }

        // Light wallet: immediately synced since LWS handles blockchain scanning server-side
        // For regular wallets: start in connecting state
        if node.isLightWallet {
            NSLog("[MoneroCore] Light wallet mode - setting state to synced immediately")
            stateManager.state = .synced
        } else {
            stateManager.state = .connecting(waiting: false)
        }

        startStateManager()
        walletListener.start(walletPointer: walletPointer)
    }

    private func stopWalletServices() {
        NSLog("[MoneroCore] stopWalletServices() called, self=\(Unmanaged.passUnretained(self).toOpaque())")
        stateManager.stop()
        walletListener.stop()
    }

    func start() {
        guard walletManagerPointer != nil else {
            logger?.error("Error: Could not get WalletManager instance.")
            return
        }

        stateManager.validateReachable()
        startCore()
        startWalletServices()
    }

    func stop() {
        NSLog("[MoneroCore] stop() called, self=\(Unmanaged.passUnretained(self).toOpaque())")
        stopWalletServices()
        stopCore()
    }

    func refresh() {
        guard let walletPtr = walletPointer else { return }
        updateBalance(walletPointer: walletPtr)
        fetchSubaddresses(walletPointer: walletPtr)
        fetchTransactions(walletPointer: walletPtr)
        storeWallet(walletPointer: walletPtr)
    }

    /// Restart sync state manager to check for new blocks
    /// Call this after pull-to-refresh or background wake to detect new blockchain activity
    func startSync() {
        // Only restart if wallet is open
        guard let walletPtr = walletPointer else { return }

        // Kick off wallet2's background refresh to actually download new blocks
        MONERO_Wallet_startRefresh(walletPtr)

        // Restart the state manager to poll sync progress
        startStateManager()
    }

    func setConnectingState(waiting: Bool) {
        stateManager.state = .connecting(waiting: waiting)
    }

    func address(index: Int) -> String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(index))) ?? ""
    }

    /// Add a new subaddress to the wallet
    /// - Parameter label: Optional label for the subaddress
    /// - Returns: The index and address of the newly created subaddress
    func addSubaddress(label: String = "") -> (index: Int, address: String)? {
        guard let walletPtr = walletPointer else { return nil }

        // Get current count before adding
        let countBefore = MONERO_Wallet_numSubaddresses(walletPtr, account)

        // Add the new subaddress
        MONERO_Wallet_addSubaddress(walletPtr, account, label)

        // Get the new count to verify
        let countAfter = MONERO_Wallet_numSubaddresses(walletPtr, account)

        // The new index is countBefore (0-indexed)
        let newIndex = Int(countBefore)

        // Get the address for the new subaddress
        guard let newAddress = stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(newIndex))) else {
            return nil
        }

        // Refresh subaddresses list
        fetchSubaddresses(walletPointer: walletPtr)

        NSLog("[MoneroCore] addSubaddress: created index=\(newIndex), countBefore=\(countBefore), countAfter=\(countAfter)")

        return (index: newIndex, address: newAddress)
    }

    func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String? = nil) throws {
        guard let walletPtr = walletPointer else {
            NSLog("[MoneroCore] send: walletPointer is nil")
            throw MoneroCoreError.walletNotInitialized
        }

        // NOTE: LightWalletTransactionBuilder (CMyMoneroCore) is DISABLED because it has
        // symbol conflicts with MoneroCombined (wallet2). Both libraries define cryptonote::account_base
        // and other classes with incompatible implementations, causing crashes.
        //
        // For now, light wallets use wallet2's LWS support, which has parsing issues ("Invalid hash field")
        // but doesn't crash. A proper fix requires either:
        // 1. Building CMyMoneroCore as a separate dynamic library with hidden symbols
        // 2. Using a server-side transaction construction approach
        // 3. Pure Swift implementation of the transaction builder
        //
        // if node.isLightWallet {
        //     NSLog("[MoneroCore] send: Using LightWalletTransactionBuilder for light wallet")
        //     try sendViaLightWalletBuilder(to: address, amount: amount, priority: priority)
        //     return
        // }

        // Log wallet2 internal state before attempting transaction
        let internalBalance = MONERO_Wallet_balance(walletPtr, account)
        let internalUnlocked = MONERO_Wallet_unlockedBalance(walletPtr, account)
        NSLog("[MoneroCore] send: INVESTIGATION - wallet2 internal state:")
        NSLog("[MoneroCore] send:   - isLightWallet: \(node.isLightWallet)")
        NSLog("[MoneroCore] send:   - balance (piconero): \(internalBalance)")
        NSLog("[MoneroCore] send:   - unlockedBalance (piconero): \(internalUnlocked)")
        NSLog("[MoneroCore] send:   - requested amount: \(amount.value)")
        NSLog("[MoneroCore] send:   - node URL: \(node.url.absoluteString)")

        // If balance is 0 in light mode, this is the core problem - wallet2 hasn't fetched outputs from LWS
        if node.isLightWallet && internalBalance == 0 {
            NSLog("[MoneroCore] send: WARNING - Light wallet mode but wallet2 balance is 0!")
            NSLog("[MoneroCore] send: wallet2 likely hasn't fetched outputs from LWS yet")
            NSLog("[MoneroCore] send: Attempting to trigger refresh and poll for balance...")

            // Try to trigger a refresh to fetch outputs from LWS
            // In light wallet mode, refresh should call /get_unspent_outs
            NSLog("[MoneroCore] send: Calling MONERO_Wallet_startRefresh...")
            MONERO_Wallet_startRefresh(walletPtr)

            // Poll for balance to become non-zero (max 30 seconds)
            let maxAttempts = 30
            var attempt = 0
            var currentBalance: UInt64 = 0

            while attempt < maxAttempts {
                Thread.sleep(forTimeInterval: 1.0)
                attempt += 1
                currentBalance = MONERO_Wallet_balance(walletPtr, account)
                let currentUnlocked = MONERO_Wallet_unlockedBalance(walletPtr, account)
                NSLog("[MoneroCore] send: Refresh poll \(attempt)/\(maxAttempts) - balance: \(currentBalance), unlocked: \(currentUnlocked)")

                if currentBalance > 0 {
                    NSLog("[MoneroCore] send: Balance found after \(attempt) seconds!")
                    break
                }

                // Try triggering refresh again every 5 seconds
                if attempt % 5 == 0 {
                    NSLog("[MoneroCore] send: Re-triggering refresh...")
                    MONERO_Wallet_startRefresh(walletPtr)
                }
            }

            if currentBalance == 0 {
                NSLog("[MoneroCore] send: ERROR - Balance still 0 after \(maxAttempts) seconds of polling")
                NSLog("[MoneroCore] send: Light wallet may not be fetching outputs from LWS correctly")
            }
        }

        NSLog("[MoneroCore] send: creating transaction to \(address.prefix(16))..., amount=\(amount.value), priority=\(priority.rawValue)")
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

        if let memo {
            let txIds = String(cString: MONERO_PendingTransaction_txid(pendingTxPtr, "|"))
            let txId = txIds.split(separator: "|").first ?? ""
            let cTxId = (txId as NSString).utf8String
            let cNote = (memo as NSString).utf8String

            MONERO_Wallet_setUserNote(walletPtr, cTxId, cNote)
        }

        if node.isLightWallet {
            // For light wallets, extract hex and submit to LWS /submit_raw_tx endpoint
            let txHexPtr = MONERO_PendingTransaction_hex(txPtr, "")
            let txHex = stringFromCString(txHexPtr) ?? ""

            if txHex.isEmpty {
                throw MoneroCoreError.transactionSendFailed("Transaction hex is empty")
            }

            NSLog("[MoneroCore] send: submitting tx to LWS, hex length=\(txHex.count)")

            // Synchronous HTTP POST to /submit_raw_tx
            let submitUrl = URL(string: "\(node.url.absoluteString)/submit_raw_tx")!
            var request = URLRequest(url: submitUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["tx": txHex])

            let semaphore = DispatchSemaphore(value: 0)
            var submitError: Error?

            URLSession.shared.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }

                if let error = error {
                    submitError = MoneroCoreError.transactionSendFailed(error.localizedDescription)
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? String else {
                    submitError = MoneroCoreError.transactionSendFailed("Invalid LWS response")
                    return
                }

                if status == "OK" {
                    NSLog("[MoneroCore] send: transaction submitted to LWS successfully")
                } else {
                    let errorMsg = json["error"] as? String ?? "Transaction rejected"
                    submitError = MoneroCoreError.transactionSendFailed(errorMsg)
                }
            }.resume()

            semaphore.wait()

            if let error = submitError {
                throw error
            }
        } else {
            // For regular wallets, use commit() to broadcast via daemon
            NSLog("[MoneroCore] send: committing transaction...")
            guard MONERO_PendingTransaction_commit(txPtr, "", false) else {
                let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
                NSLog("[MoneroCore] send: commit failed, error='\(error)'")
                throw MoneroCoreError.transactionCommitFailed(error)
            }
            NSLog("[MoneroCore] send: transaction committed successfully")
        }

        startStateManager()
    }

    /// Send transaction using LightWalletTransactionBuilder (CMyMoneroCore JSON serial bridge)
    /// This is used for light wallets instead of wallet2's createTransaction which has parsing issues
    private func sendViaLightWalletBuilder(to destinationAddress: String, amount: SendAmount, priority: SendPriority) throws {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        // Extract wallet keys from wallet2
        guard let walletAddress = stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0)),
              let privateViewKey = stringFromCString(MONERO_Wallet_secretViewKey(walletPtr)),
              let privateSpendKey = stringFromCString(MONERO_Wallet_secretSpendKey(walletPtr)),
              let publicSpendKey = stringFromCString(MONERO_Wallet_publicSpendKey(walletPtr)) else {
            NSLog("[MoneroCore] sendViaLightWalletBuilder: Failed to extract wallet keys")
            throw MoneroCoreError.transactionSendFailed("Failed to extract wallet keys")
        }

        NSLog("[MoneroCore] sendViaLightWalletBuilder: wallet address: \(walletAddress.prefix(16))...")
        NSLog("[MoneroCore] sendViaLightWalletBuilder: destination: \(destinationAddress.prefix(16))...")
        NSLog("[MoneroCore] sendViaLightWalletBuilder: amount: \(amount.value)")

        // Determine network type
        let netType: LightWalletNetType
        switch networkType {
        case .mainnet:
            netType = .mainnet
        case .testnet:
            netType = .testnet
        }

        // Create the builder
        let builder = LightWalletTransactionBuilder(
            serverURL: node.url,
            address: walletAddress,
            privateViewKey: privateViewKey,
            privateSpendKey: privateSpendKey,
            publicSpendKey: publicSpendKey,
            netType: netType
        )

        // Convert priority
        let lwPriority: LightWalletPriority
        switch priority {
        case .low:
            lwPriority = .low
        case .default:
            lwPriority = .medLow
        case .medium:
            lwPriority = .medHigh
        case .high, .last:
            lwPriority = .high
        }

        // Use a semaphore to wait for async completion
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<LightWalletTransactionResult, Error>?

        builder.send(
            toAddress: destinationAddress,
            amount: amount.value,
            priority: lwPriority,
            isSweeping: false,
            onStatusUpdate: { status in
                NSLog("[MoneroCore] sendViaLightWalletBuilder: \(status)")
            },
            completion: { txResult in
                result = txResult
                semaphore.signal()
            }
        )

        // Wait for completion (max 2 minutes)
        let timeout = DispatchTime.now() + .seconds(120)
        if semaphore.wait(timeout: timeout) == .timedOut {
            NSLog("[MoneroCore] sendViaLightWalletBuilder: Transaction timed out")
            throw MoneroCoreError.transactionSendFailed("Transaction creation timed out")
        }

        // Handle result
        switch result {
        case .success(let tx):
            NSLog("[MoneroCore] sendViaLightWalletBuilder: Transaction created successfully!")
            NSLog("[MoneroCore] sendViaLightWalletBuilder: txHash: \(tx.txHash)")
            NSLog("[MoneroCore] sendViaLightWalletBuilder: fee: \(tx.usedFee)")
            // Transaction is already submitted by LightWalletTransactionBuilder
            // Trigger a refresh to update balance
            startStateManager()

        case .failure(let error):
            NSLog("[MoneroCore] sendViaLightWalletBuilder: Transaction failed: \(error)")
            if let lwError = error as? LightWalletError {
                switch lwError {
                case .insufficientFunds(let spendable, let required):
                    throw MoneroCoreError.transactionSendFailed("Insufficient funds: have \(spendable), need \(required)")
                case .transactionCreationFailed(let msg):
                    throw MoneroCoreError.transactionSendFailed(msg)
                case .networkError(let msg):
                    throw MoneroCoreError.transactionSendFailed("Network error: \(msg)")
                case .serverError(let msg):
                    throw MoneroCoreError.transactionSendFailed("Server error: \(msg)")
                default:
                    throw MoneroCoreError.transactionSendFailed(error.localizedDescription)
                }
            } else {
                throw MoneroCoreError.transactionSendFailed(error.localizedDescription)
            }

        case .none:
            NSLog("[MoneroCore] sendViaLightWalletBuilder: No result received")
            throw MoneroCoreError.transactionSendFailed("No result received from transaction builder")
        }
    }

    func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        guard let walletPtr = walletPointer else {
            NSLog("[MoneroCore] estimateFee: walletPointer is nil, self=\(Unmanaged.passUnretained(self).toOpaque())")
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let cAmount = ("\(amount.value)" as NSString).utf8String
        NSLog("[MoneroCore] estimateFee: calling with amount=\(amount.value), priority=\(priority.rawValue)")
        let fee = MONERO_Wallet_estimateTransactionFee(walletPtr, cAddress, "", cAmount, "", Int32(priority.rawValue))
        let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? ""
        NSLog("[MoneroCore] estimateFee: fee=\(fee), error='\(error)'")
        if !error.isEmpty, error != "No error" {
            // For light wallets, certain errors are expected - they use LWS instead of daemon RPC
            // If we got a valid fee, return it despite these benign errors
            if node.isLightWallet && fee > 0 {
                let lowerError = error.lowercased()
                if lowerError.contains("no connection") || lowerError.contains("invalid hash field") {
                    NSLog("[MoneroCore] estimateFee: ignoring benign error for light wallet, returning fee=\(fee)")
                    return fee
                }
            }
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
            resolvedSeedPhrase = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case let .polyseed(mnemonic, passphrase):
            resolvedSeedPhrase = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case .watch:
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
        }
    }
}

protocol MoneroCoreDelegate: AnyObject {
    func balanceDidChange(balance: MoneroCore.Balance)
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress])
    func walletStateDidChange(state: WalletState)
}
