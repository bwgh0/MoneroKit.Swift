import Foundation
import HsToolKit

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10

    private let moneroCore: MoneroCore
    private let storage: GrdbStorage
    private let kitId = UUID().uuidString
    private let lifecycleQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.kit_lifecycle_queue", qos: .background)
    private var started = false

    public weak var delegate: MoneroKitDelegate?

    public init(wallet: MoneroWallet, account: UInt32, restoreHeight: UInt64 = 0, walletId: String, node: Node, networkType: NetworkType = .mainnet, reachabilityManager: ReachabilityManager, logger: Logger?, moneroCoreLogLevel: Int32? = nil) throws {
        let baseDirectoryName = "MoneroKit/\(walletId)/network_\(networkType.rawValue)"
        let baseDirectoryUrl = try FileHandler.directoryURL(for: baseDirectoryName)

        let databasePath = baseDirectoryUrl.appendingPathComponent("storage").path
        storage = GrdbStorage(databaseFilePath: databasePath)

        let walletDirectoryName = "\(baseDirectoryName)/monero_core"
        if storage.getBlockHeights() == nil {
            try FileHandler.remove(for: walletDirectoryName)
        }

        let walletPath = try FileHandler.directoryURL(for: walletDirectoryName).appendingPathComponent("wallet").path
        let logger = logger ?? Logger(minLogLevel: .verbose)

        moneroCore = MoneroCore(
            wallet: wallet,
            account: account,
            walletPath: walletPath,
            walletPassword: walletId,
            node: node,
            restoreHeight: restoreHeight,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: logger,
            moneroCoreLogLevel: moneroCoreLogLevel
        )

        moneroCore.delegate = self

        let existingAddresses = storage.getAllAddresses()
        if existingAddresses.isEmpty {
            // Try static address derivation - works for BIP39 and legacy, but NOT polyseed
            // For polyseed, addresses will be populated after wallet opens via start()
            do {
                let primaryAddress = try MoneroCore.address(wallet: wallet, account: account, index: 0, networkType: networkType)
                storage.add(subAddress: SubAddress(address: primaryAddress, index: 0))

                if account == 0 {
                    if case .watch = wallet {
                        return
                    }

                    let firstSubAddress = try MoneroCore.address(wallet: wallet, account: account, index: 1, networkType: networkType)
                    storage.add(subAddress: SubAddress(address: firstSubAddress, index: 1))
                }
            } catch {
                // Static address derivation failed (likely polyseed)
                // Addresses will be populated when wallet opens via start()
            }
        }
    }

    deinit {
        _stop()
    }

    // Methods interacting with wallet cache in storage

    public var lastBlockInfo: UInt64 {
        var walletHeight = moneroCore.blockHeights?.0
        if walletHeight == nil {
            walletHeight = storage.getBlockHeights().map { UInt64($0.walletHeight) }
        }

        return walletHeight ?? 0
    }

    /// Current block heights: (walletHeight, daemonHeight)
    /// Returns nil if heights are not yet available (still connecting)
    public var blockHeights: (walletHeight: UInt64, daemonHeight: UInt64)? {
        if let heights = moneroCore.blockHeights {
            return (walletHeight: heights.0, daemonHeight: heights.1)
        }
        // Fallback to storage if runtime heights not available
        if let stored = storage.getBlockHeights() {
            return (walletHeight: UInt64(stored.walletHeight), daemonHeight: UInt64(stored.daemonHeight))
        }
        return nil
    }

    public var walletState: WalletState {
        moneroCore.state
    }

    public var balanceInfo: BalanceInfo {
        let balanceRecord = storage.getBalance()
        return balanceRecord.map { BalanceInfo(balance: $0) } ?? .init(all: 0, unlocked: 0)
    }

    public var receiveAddress: String {
        storage.getLastUnusedAddress()?.address ?? ""
    }

    /// Primary address (index 0) - from storage (pre-computed)
    public var primaryAddress: String {
        storage.getAddress(index: 0)?.address ?? ""
    }

    /// Primary address directly from wallet2 runtime - use for light wallet mode
    /// This ensures the address matches what wallet2 actually uses internally
    public var runtimePrimaryAddress: String {
        moneroCore.address(index: 0)
    }

    public var usedAddresses: [SubAddress] {
        storage.getAllAddresses()
    }

    public var statusInfo: [(String, Any)] {
        var status = [(String, Any)]()

        let (walletHeight, daemonHeight) = moneroCore.blockHeights.map { ("\($0)", "\($1)") } ?? ("n/a", "n/a")
        let lastSyncedWalletHeight = storage.getBlockHeights().map { "\($0.walletHeight)" } ?? "n/a"
        status.append(("Wallet Status", walletState.description))
        status.append(("Last Block Height", "\(lastBlockInfo)"))
        status.append(("Last Synced Wallet Height", lastSyncedWalletHeight))
        status.append(("Wallet Height", walletHeight))
        status.append(("Daemon Height", daemonHeight))
        status.append(("Kit started", started ? "yes" : "no"))
        status.append(("Node", moneroCore.node.description))

        return status
    }

    public func transactions(fromHash: String? = nil, descending: Bool, type: TransactionFilterType?, limit: Int?) -> [TransactionInfo] {
        var resolvedTimestamp: Int?

        if let fromHash, let transaction = storage.transaction(byHash: fromHash) {
            resolvedTimestamp = transaction.timestamp
        }

        return storage
            .transactions(fromTimestamp: resolvedTimestamp, descending: descending, type: type, limit: limit)
            .map { TransactionInfo(transaction: $0) }
    }

    // Methods interacting with moneroCore

    private func _start() {
        guard !started else { return }
        started = true

        var kitState = KitManager.shared.checkAndGetInitialState(kitId: kitId)

        while kitState == .waiting {
            moneroCore.setConnectingState(waiting: true)
            Thread.sleep(forTimeInterval: 1.0)
            kitState = KitManager.shared.checkAndGetState(kitId: kitId)
        }

        if kitState == .running {
            moneroCore.setConnectingState(waiting: false)
            moneroCore.start()

            // For polyseed wallets, storage may be empty because static address derivation fails
            // Populate addresses now that wallet is open and walletPointer is set
            let currentAddresses = storage.getAllAddresses()

            // Ensure primary address (index 0) exists - may be missing for polyseed
            let hasIndex0 = currentAddresses.contains { $0.index == 0 && !$0.address.isEmpty }
            if !hasIndex0 {
                let primaryAddress = moneroCore.address(index: 0)
                if !primaryAddress.isEmpty {
                    storage.add(subAddress: SubAddress(address: primaryAddress, index: 0))

                    // Also ensure first subaddress for account 0
                    let hasIndex1 = currentAddresses.contains { $0.index == 1 && !$0.address.isEmpty }
                    if !hasIndex1 {
                        let firstSubAddress = moneroCore.address(index: 1)
                        if !firstSubAddress.isEmpty {
                            storage.add(subAddress: SubAddress(address: firstSubAddress, index: 1))
                        }
                    }

                    // Notify delegate that addresses are now available
                    delegate?.subAddressesUpdated(subaddresses: storage.getAllAddresses())
                }
            }
        }
    }

    private func _stop() {
        guard started else { return }
        started = false
        NSLog("[Kit] _stop() called, kitId=\(kitId)")
        Thread.callStackSymbols.prefix(10).forEach { NSLog("[Kit] stack: \($0)") }

        moneroCore.stop()
        KitManager.shared.removeRunning(kitId: kitId)
    }

    private func _restart() {
        if case .idle = moneroCore.state { return }

        _stop()

        if !KitManager.shared.waitingKitExists() {
            _start()
        }
    }

    public func start() {
        // Use strong self to prevent deallocation during async startup
        // The Kit MUST remain alive while wallet2 is initializing
        lifecycleQueue.async { [self] in self._start() }
    }

    public func stop() {
        lifecycleQueue.async { [weak self] in self?._stop() }
    }

    public func refresh() {
        guard KitManager.shared.isRunning(kitId: kitId) else { return }

        switch moneroCore.state {
        case .connecting, .syncing, .synced: moneroCore.refresh()
        case .notSynced: restart()
        case .idle: ()
        }
    }

    public func restart() {
        lifecycleQueue.async { [weak self] in self?._restart() }
    }

    /// Restart sync state checking to detect new blocks
    /// Call this after a period of inactivity to check for new blockchain activity
    public func startSync() {
        moneroCore.startSync()
    }

    public func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String?) throws {
        try moneroCore.send(to: address, amount: amount, priority: priority, memo: memo)
    }

    public func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        try moneroCore.estimateFee(address: address, amount: amount, priority: priority)
    }

    /// Create a new subaddress
    /// - Parameter label: Optional label for the subaddress
    /// - Returns: The newly created SubAddress, or nil if creation failed
    public func createSubaddress(label: String = "") -> SubAddress? {
        guard let result = moneroCore.addSubaddress(label: label) else {
            return nil
        }

        let newSubAddress = SubAddress(address: result.address, index: result.index)
        storage.add(subAddress: newSubAddress)
        delegate?.subAddressesUpdated(subaddresses: storage.getAllAddresses())

        return newSubAddress
    }
}

extension Kit: MoneroCoreDelegate {
    func walletStateDidChange(state: WalletState) {
        delegate?.walletStateDidChange(state: state)

        // Don't auto-stop on error - let the app handle via delegate
        // if case .notSynced = state {
        //     stop()
        // }

        if let (walletHeight, daemonHeight) = moneroCore.blockHeights {
            storage.update(blockHeights: BlockHeights(daemonHeight: Int(daemonHeight), walletHeight: Int(walletHeight)))
        }
    }

    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress]) {
        if moneroCore.account == 0 && subAddresses.count <= 1 {
            // 0 account must keep 2 addresses created on Kit initialization
            return
        } else if subAddresses.count == 0 {
            // > 0 accounts must keep 1 address created on Kit initialization
            return
        }

        let subAddresses = subAddresses.map { SubAddress(address: $0.address, index: $0.index) }
        storage.update(subAddresses: subAddresses)
        delegate?.subAddressesUpdated(subaddresses: subAddresses)
    }

    func balanceDidChange(balance: MoneroCore.Balance) {
        let balanceRecord = Balance(all: balance.all, unlocked: balance.unlocked)
        storage.update(balance: balanceRecord)
        delegate?.balanceDidChange(balanceInfo: BalanceInfo(balance: balanceRecord))
    }

    func transactionsDidChange(transactions: [MoneroCore.Transaction]) {
        let transactionRecords = transactions.compactMap { transaction in
            let type = transaction.direction == .in ? TransactionType.incoming : .outgoing
            var recipientAddress: String? = nil

            if type == .incoming,
               let subAddressIndex = transaction.subaddrIndices.first,
               let address = storage.getAddress(index: subAddressIndex)
            {
                recipientAddress = address.address
            }

            return Transaction(
                hash: transaction.hash,
                type: type,
                blockHeight: transaction.blockHeight,
                amount: transaction.amount,
                fee: transaction.fee,
                isPending: transaction.isPending,
                isFailed: transaction.isFailed,
                timestamp: Int(transaction.timestamp.timeIntervalSince1970),
                note: transaction.note,
                recipientAddress: recipientAddress
            )
        }

        storage.update(transactions: transactionRecords)

        let transactionInfos = transactionRecords.map { TransactionInfo(transaction: $0) }
        delegate?.transactionsUpdated(inserted: [], updated: transactionInfos)

        // Mark used addresses
        var usedAddresses: [Int: Int] = Dictionary()
        for transaction in transactions {
            guard transaction.direction == .in else { continue }
            for index in transaction.subaddrIndices {
                usedAddresses[index] = (usedAddresses[index] ?? 0) + 1
            }
        }

        for (index, txCount) in usedAddresses {
            storage.setAddressTransactionsCount(index: index, txCount: txCount)
        }

        // Generate extra unused addresses
        if let lastUsedAddressIndex = usedAddresses.keys.max() {
            // We assume that there's at least 2 addresses in storage. Even if there's no transactions.
            let extraAddress = moneroCore.address(index: lastUsedAddressIndex + 1)
            storage.add(subAddress: SubAddress(address: extraAddress, index: lastUsedAddressIndex + 1))
        }
    }
}

public extension Kit {
    static func removeAll(except excludedFiles: [String]) throws {
        try FileHandler.removeAll(except: excludedFiles)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(address: address, networkType: networkType)
    }

    static func isValid(viewKey: String, address: String, isViewKey: Bool, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(viewKey: viewKey, address: address, isViewKey: isViewKey, networkType: networkType)
    }

    static func key(wallet: MoneroWallet, privateKey: Bool, spendKey: Bool) throws -> String? {
        try MoneroCore.key(wallet: wallet, privateKey: privateKey, spendKey: spendKey)
    }

    /// Derive address from wallet credentials without initializing Kit
    /// This is synchronous and works offline - pure cryptographic derivation
    static func address(wallet: MoneroWallet, account: UInt32 = 0, index: UInt32 = 0, networkType: NetworkType = .mainnet) throws -> String {
        try MoneroCore.address(wallet: wallet, account: account, index: index, networkType: networkType)
    }
}

public enum MoneroKitError: Error {
    case invalidWalletId
    case invalidSeed
}

public protocol MoneroKitDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func subAddressesUpdated(subaddresses: [SubAddress])
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func walletStateDidChange(state: WalletState)
}
