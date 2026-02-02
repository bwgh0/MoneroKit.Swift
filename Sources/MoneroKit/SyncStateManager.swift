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

    let queue = DispatchQueue(label: "io.horizontalsystems.monero_kit.core_state_queue", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let timerLock = NSLock()

    private var connectStartTime: Date?
    private var backgroundSyncSetupSuccess: Bool = false
    private var restoreHeight: UInt64
    private var lastStoredBlockHeight: UInt64 = 0
    private var status: WalletCoreStatus = .unknown
    private var isSynchronized: Bool = false
    private var daemonHeight: UInt64 = 0
    private(set) var walletHeight: UInt64 = 0
    private(set) var blockHeights: (UInt64, UInt64)?

    var onSyncStateChanged: (() -> Void)?

    var state: WalletState = .notSynced(error: WalletStateError.notStarted) {
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

    init(logger: Logger?, restoreHeight: UInt64, reachabilityManager: ReachabilityManager) {
        self.logger = logger
        self.reachabilityManager = reachabilityManager
        self.restoreHeight = restoreHeight

        reachabilityManager.$isReachable
            .receive(on: queue)
            .sink { [weak self] isReachable in
                self?.state = .idle(daemonReachable: isReachable)
            }
            .store(in: &cancellables)
    }

    private func evaluateState() -> WalletState {
        guard reachabilityManager.isReachable else {
            return .idle(daemonReachable: false)
        }

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

        blockHeights = (walletHeight, daemonHeight)
        return .syncing(progress: numberOfBlocksSynced * 100 / numberOfBlocksToSync, remainingBlocksCount: numberOfBlocksToSync - numberOfBlocksSynced)
    }

    private func checkSyncState() {
        timerLock.lock()
        guard isRunning, let walletPtr = walletPointer else {
            timerLock.unlock()
            return
        }
        timerLock.unlock()

        walletHeight = MONERO_Wallet_blockChainHeight(walletPtr)
        isSynchronized = MONERO_Wallet_synchronized(walletPtr)
        let status = MONERO_Wallet_status(walletPtr)

        if status != 0 {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let errorStr = stringFromCString(errorCStr) ?? "Unknown wallet error"
            logger?.error("Wallet is in error state (\(status)): \(errorStr).")
            state = .notSynced(error: WalletStateError.statusError(errorStr))
            return
        }

        if lastStoredBlockHeight < restoreHeight {
            lastStoredBlockHeight = walletHeight
        }

        daemonHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)

        state = evaluateState()

        scheduleNextCheck()
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

    func stop() {
        timerLock.lock()
        isRunning = false
        timer?.cancel()
        timer = nil
        timerLock.unlock()

//        if let walletPtr = walletPointer {
//            let stopped = MONERO_Wallet_stopBackgroundSync(walletPtr, cWalletPassword)
//            if !stopped {
//                let errorCStr = MONERO_Wallet_errorString(walletPtr)
//                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
//                logger?.error("Error stop Background sync: \(msg)")
//                return
//            }
//        }
        connectStartTime = nil

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
