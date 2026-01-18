import MoneroKit
import SwiftUI

struct WalletDashboardView: View {
    @Binding var moneroKit: Kit?
    @ObservedObject var walletState: App_WalletState

    var body: some View {
        List {
            Section(header: Text("Wallet Status")) {
                Text("State: \(stateDescription(walletState.walletState))")
                Text("Wallet Height: \(moneroKit?.lastBlockInfo ?? 0)")
                Text("Balance: \(Double(walletState.balance.unlocked) / 1_000_000_000_000) XMR")
            }

            Section(header: Text("Actions")) {
                NavigationLink(destination: SubaddressesView(moneroKit: $moneroKit)) {
                    Text("Receive")
                }
                NavigationLink(destination: SendView(moneroKit: $moneroKit)) {
                    Text("Send")
                }
            }

            Section(header: Text("Transactions")) {
                if walletState.transactions.isEmpty {
                    Text("No transactions yet.")
                } else {
                    ForEach(walletState.transactions, id: \.hash) { tx in
                        VStack(alignment: .leading) {
                            Text("Hash: \(tx.hash)")
                                .font(.caption)
                                .lineLimit(1)
                            Text("Amount: \(Double(tx.amount) / 1_000_000_000_000, specifier: "%.6f") XMR")
                            Text("Direction: \(tx.type.description)")
                            if let recipient = tx.recipientAddress {
                                Text("To: \(recipient)")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Text("Date: \(Date(timeIntervalSince1970: TimeInterval(tx.timestamp)), formatter: itemFormatter)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
    }

    private func stateDescription(_ state: WalletState) -> String {
        switch state {
            case .connecting: return "Connecting..."
            case .syncing(let progress, let remainingBlocksCount): return "Syncing (\(progress)%, \(remainingBlocksCount) blocks remaining)"
            case .synced: return "Synced"
            case .idle(let daemonReachable): return "Idle \(daemonReachable ? "🔹" : "❌")"
            case .notSynced(let error): return "Not Synced: \(error)"
        }
    }
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

extension TransactionType {
    var description: String {
        switch self {
        case .incoming: return "Incoming"
        case .outgoing: return "Outgoing"
        case .sentToSelf: return "Sent to Self"
        }
    }
}
