import CMonero
import Foundation

class WalletListener {
    private var walletListenerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var isRunning = false
    private var lockedBalanceBlockHeight: UInt64?
    private let listenerQueue = DispatchQueue(label: "monero.kit.wallet-listener-queue", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let timerLock = NSLock()
    var onNewTransaction: (() -> Void)?

    private func checkListener() {
        timerLock.lock()
        guard isRunning, let listenerPtr = walletListenerPointer else {
            timerLock.unlock()
            return
        }
        timerLock.unlock()

        let hasNewTransaction = MONERO_cw_WalletListener_isNewTransactionExist(listenerPtr)
        if hasNewTransaction {
            // Has new transaction
            onNewTransaction?()
            MONERO_cw_WalletListener_resetIsNewTransactionExist(listenerPtr)
        }

        if let height = lockedBalanceBlockHeight {
            let newHeight = MONERO_cw_WalletListener_height(listenerPtr)
            if newHeight > height, newHeight - height >= Kit.confirmationsThreshold {
                // Previously confirmed transaction has enough confirmations for the locked balance to be updated.
                onNewTransaction?()
                lockedBalanceBlockHeight = nil
            }
        }

        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        timerLock.lock()
        defer { timerLock.unlock() }

        guard isRunning else { return }

        timer?.cancel()
        timer = nil

        let newTimer = DispatchSource.makeTimerSource(queue: listenerQueue)
        newTimer.schedule(deadline: .now() + 1)
        newTimer.setEventHandler { [weak self] in
            self?.checkListener()
        }
        timer = newTimer
        newTimer.resume()
    }

    func start(walletPointer: UnsafeMutableRawPointer?) {
        guard !isRunning else { return }
        isRunning = true

        self.walletPointer = walletPointer

        walletListenerPointer = MONERO_cw_getWalletListener(walletPointer)
        MONERO_Wallet_startRefresh(walletPointer)

        scheduleNextCheck()
    }

    func stop() {
        timerLock.lock()
        isRunning = false
        timer?.cancel()
        timer = nil
        timerLock.unlock()

        onNewTransaction = nil
        walletListenerPointer = nil

        if let walletPointer {
            MONERO_Wallet_stop(walletPointer)
        }
        walletPointer = nil
    }

    func setLockedBalanceHeight(height: UInt64) {
        if lockedBalanceBlockHeight == nil {
            lockedBalanceBlockHeight = height
        }
    }
}
