import CMonero
import Combine
import Foundation
import HsToolKit

class SyncStateManager {
    static let storeBlocksCount: UInt64 = 2000
    static let connectTimeout: TimeInterval = 30

    private var cancellables = Set<AnyCancellable>()
    private var reachabilityManager: ReachabilityManager
    private let logger: Logger?
    private var isRunning = false
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?

    private static let queueKey = DispatchSpecificKey<Bool>()
    let queue: DispatchQueue
    private let workerQueue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let timerLock = NSLock()
    private var isCheckInFlight = false

    private var connectStartTime: Date?
    private var walletReadyTime: Date?  // Legacy — kept for potential future use
    private var hasConnectedOnce: Bool = false  // Track if we've established daemon connection
    private var backgroundSyncSetupSuccess: Bool = false
    private var restoreHeight: UInt64
    private var lastStoredBlockHeight: UInt64 = 0
    private var status: WalletCoreStatus = .unknown
    private var isSynchronized: Bool = false
    private var daemonHeight: UInt64 = 0
    private(set) var walletHeight: UInt64 = 0
    private(set) var blockHeights: (UInt64, UInt64)?

    var onSyncStateChanged: (() -> Void)?

    var state: WalletState = .idle(daemonReachable: false) {
        didSet {
            if oldValue != state {
                onSyncStateChanged?()
            }
        }
    }

    var chunkOfBlocksSynced: Bool {
        // Blocks before restore height are synced without transactions
        if lastStoredBlockHeight < restoreHeight {
            return false
        }

        return lastStoredBlockHeight <= walletHeight && walletHeight - lastStoredBlockHeight >= Self.storeBlocksCount
    }

    func updateRestoreHeight(_ height: UInt64) {
        restoreHeight = height
    }

    init(logger: Logger?, restoreHeight: UInt64, reachabilityManager: ReachabilityManager) {
        self.logger = logger
        self.reachabilityManager = reachabilityManager
        self.restoreHeight = restoreHeight

        self.queue = DispatchQueue(label: "io.horizontalsystems.monero_kit.core_state_queue", qos: .userInitiated)
        self.workerQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.core_worker_queue", qos: .background)
        queue.setSpecific(key: Self.queueKey, value: true)

        reachabilityManager.$isReachable
            .receive(on: queue)
            .sink { [weak self] isReachable in
                self?.state = .idle(daemonReachable: isReachable)
            }
            .store(in: &cancellables)
    }

    private func evaluateState() -> WalletState {
        // Always keep blockHeights current for confirmation calculations
        if walletHeight > 0, daemonHeight > 0 {
            blockHeights = (walletHeight, daemonHeight)
        }

        guard reachabilityManager.isReachable else {
            return .idle(daemonReachable: false)
        }

        // Timeout if daemon height never arrives — use connectStartTime so the
        // timeout fires even on fresh wallets where walletHeight is still 0
        if daemonHeight == 0, let connectStartTime, Date().timeIntervalSince(connectStartTime) > Self.connectTimeout {
            return .notSynced(error: .statusError("Connection timed out"))
        }

        guard daemonHeight > 0, daemonHeight >= restoreHeight, walletHeight >= restoreHeight else {
            return .connecting(waiting: false)
        }

        if daemonHeight == walletHeight, isSynchronized {
            return .synced
        }

        let numberOfBlocksToSync = Int(daemonHeight - restoreHeight)
        let numberOfBlocksSynced = Int(walletHeight - restoreHeight)
        if numberOfBlocksToSync == 0 {
            return .syncing(progress: 100, remainingBlocksCount: 0)
        }

        return .syncing(progress: numberOfBlocksSynced * 100 / numberOfBlocksToSync, remainingBlocksCount: numberOfBlocksToSync - numberOfBlocksSynced)
    }

    private func checkSyncState() {
        timerLock.lock()
        guard isRunning, let walletPtr = walletPointer else {
            timerLock.unlock()
            return
        }
        timerLock.unlock()

        // Dispatch blocking C++ calls to worker queue if none are in-flight
        if !isCheckInFlight {
            isCheckInFlight = true
            workerQueue.async { [weak self] in
                // These C++ calls may block for 30+ seconds when wallet2's
                // refresh thread holds internal locks during slow daemon I/O
                let height = MONERO_Wallet_blockChainHeight(walletPtr)
                let synchronized = MONERO_Wallet_synchronized(walletPtr)
                let status = MONERO_Wallet_status(walletPtr)
                let errorStr: String? = status != 0
                    ? stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown wallet error"
                    : nil
                let dHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)

                self?.queue.async {
                    self?.applyCheckResults(
                        walletHeight: height,
                        isSynchronized: synchronized,
                        status: status,
                        errorStr: errorStr,
                        daemonHeight: dHeight
                    )
                }
            }
        }

        // Always evaluate state with current (possibly stale) values so
        // timeout detection and state callbacks keep working
        state = evaluateState()

        // Always schedule the next check so polling never stops
        scheduleNextCheck()
    }

    /// Apply results from the worker queue's C++ calls and re-evaluate state.
    /// Called on `queue`.
    private func applyCheckResults(
        walletHeight: UInt64,
        isSynchronized: Bool,
        status: Int32,
        errorStr: String?,
        daemonHeight: UInt64
    ) {
        isCheckInFlight = false

        guard isRunning else { return }

        self.walletHeight = walletHeight
        self.isSynchronized = isSynchronized

        if walletHeight > 0 && walletReadyTime == nil {
            walletReadyTime = Date()
        }

        if let errorStr, status != 0 {
            logger?.error("Wallet is in error state (\(status)): \(errorStr).")
            if hasConnectedOnce {
                state = .notSynced(error: WalletStateError.statusError(errorStr))
                return
            }
        }

        if lastStoredBlockHeight < restoreHeight {
            lastStoredBlockHeight = walletHeight
        }

        self.daemonHeight = daemonHeight

        if daemonHeight > 0 && !hasConnectedOnce {
            hasConnectedOnce = true
        }

        state = evaluateState()
    }

    private func scheduleNextCheck() {
        timerLock.lock()
        defer { timerLock.unlock() }

        guard isRunning else { return }

        timer?.cancel()
        timer = nil

        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + 2)
        newTimer.setEventHandler { [weak self] in
            self?.checkSyncState()
        }
        timer = newTimer
        newTimer.resume()
    }

    func validateReachable() {
        if !reachabilityManager.isReachable {
            state = .idle(daemonReachable: false)
        }
    }

    func start(walletPointer: UnsafeMutableRawPointer?, cWalletPassword: UnsafeMutablePointer<CChar>?) {
        guard let walletPointer, let cWalletPassword else { return }

        if isRunning { return }
        isRunning = true

        self.walletPointer = walletPointer
        self.cWalletPassword = cWalletPassword
        connectStartTime = Date()

//        if !backgroundSyncSetupSuccess {
//            backgroundSyncSetupSuccess = MONERO_Wallet_setupBackgroundSync(walletPointer, BackgroundSyncType.customPassword.rawValue, cWalletPassword, "")
//
//            if !backgroundSyncSetupSuccess {
//                let errorCStr = MONERO_Wallet_errorString(walletPointer)
//                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
//                logger?.error("Error setup Background sync: \(msg)")
//                return
//            }
//        }
//
//        let startedBackgroundSync = MONERO_Wallet_startBackgroundSync(walletPointer)
//        if !startedBackgroundSync {
//            let errorCStr = MONERO_Wallet_errorString(walletPointer)
//            let msg = stringFromCString(errorCStr) ?? "Start background sync error"
//            logger?.error("Error start Background sync: \(msg)")
//            return
//        }

        scheduleNextCheck()
    }

    /// Pause polling without destroying state — sync can resume via start()
    func pause() {
        timerLock.lock()
        isRunning = false
        timer?.cancel()
        timer = nil
        timerLock.unlock()

        // Wait for any in-flight C++ calls to finish before pausing refresh,
        // so we don't call pauseRefresh while the worker is still reading wallet state
        workerQueue.sync { }

        if let walletPointer {
            MONERO_Wallet_pauseRefresh(walletPointer)
        }
    }

    func stop() {
        timerLock.lock()
        isRunning = false
        timer?.cancel()
        timer = nil
        timerLock.unlock()

        // Wait for any in-flight checkSyncState() to complete before clearing pointer
        // This prevents use-after-free when wallet is deallocated
        // Check if already on queue to avoid deadlock
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync { }
        }

        // Drain the worker queue so no C++ calls are in-flight when we nil the pointer
        workerQueue.sync { }

        isCheckInFlight = false

        connectStartTime = nil
        walletReadyTime = nil
        hasConnectedOnce = false

        if let walletPointer {
            MONERO_Wallet_pauseRefresh(walletPointer)
        }

        walletPointer = nil
        cWalletPassword = nil
        onSyncStateChanged = nil  // Clear callback to prevent use-after-free
    }

    func walletStored() {
        lastStoredBlockHeight = walletHeight
    }

    enum BackgroundSyncType: Int32 {
        case none = 0
        case `default` = 1
        case customPassword = 2
    }
}
