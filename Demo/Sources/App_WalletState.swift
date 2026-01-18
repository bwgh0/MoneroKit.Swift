import Combine
import Foundation
import MoneroKit

class App_WalletState: ObservableObject, MoneroKitDelegate {
    @Published var balance: BalanceInfo = .init(all: 0, unlocked: 0)
    @Published var transactions: [TransactionInfo] = []
    @Published var walletState: WalletState = .notSynced(error: .notStarted)

    // To replace walletService.walletPointer != nil logic
    @Published var isConnected: Bool = false

    var isSynchronized: Bool {
        if case .synced = walletState {
            return true
        }
        return false
    }

    func balanceDidChange(balanceInfo: BalanceInfo) {
        DispatchQueue.main.async {
            self.balance = balanceInfo
        }
    }

    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo]) {
        DispatchQueue.main.async {
            self.transactions = inserted + updated
        }
    }

    func walletStateDidChange(state: WalletState) {
        DispatchQueue.main.async {
            self.walletState = state
        }
    }

    func subAddressesUpdated(subaddresses: [SubAddress]) {}
}