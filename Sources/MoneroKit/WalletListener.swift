import CMonero
import Foundation

class WalletListener {
    private var walletListenerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var isRunning = false
    private var lockedBalanceBlockHeight: UInt64?
    private let queue = DispatchQueue(label: "monero.kit.wallet-listener-queue", qos: .userInitiated)
    var onNewTransaction: (() -> Void)?

    private func checkListener() {
        guard let walletListenerPointer else { return }

        let hasNewTransaction = MONERO_cw_WalletListener_isNewTransactionExist(walletListenerPointer)
        if hasNewTransaction {
            // Has new transaction
            onNewTransaction?()
            MONERO_cw_WalletListener_resetIsNewTransactionExist(walletListenerPointer)
        }

        if let height = lockedBalanceBlockHeight {
            let newHeight = MONERO_cw_WalletListener_height(walletListenerPointer)
            if newHeight > height, newHeight - height >= Kit.confirmationsThreshold {
                // Previously confirmed transaction has enough confirmations for the locked balance to be updated.
                onNewTransaction?()
                lockedBalanceBlockHeight = nil
            }
        }

        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        guard isRunning else { return }

        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkListener()
        }
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
        isRunning = false
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
