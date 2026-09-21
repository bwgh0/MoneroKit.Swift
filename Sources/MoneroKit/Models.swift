import Foundation

public struct Transfer {
    public let address: String
    public let amount: UInt64
}

/// One output of an outgoing transaction: the address paid and the amount
/// in piconero (same unit as `TransactionInfo.fee`).
///
/// wallet2 only knows destinations for transactions this wallet built
/// itself (`TransactionInfo::transfers()`); they are not on chain, so an
/// outgoing transaction seen by a wallet restored from seed has none.
public struct TransactionDestination: Equatable, Hashable, Codable {
    public let address: String
    public let amount: UInt64

    public init(address: String, amount: UInt64) {
        self.address = address
        self.amount = amount
    }
}

public enum TransactionFilterType {
    case incoming, outgoing

    var types: [TransactionType] {
        switch self {
        case .incoming: return [.incoming, .sentToSelf]
        case .outgoing: return [.outgoing, .sentToSelf]
        }
    }
}

public struct TransactionInfo {
    public let uid: String
    public let hash: String
    public let type: TransactionType
    public let blockHeight: UInt64
    public let amount: Int64
    public let fee: UInt64
    public let isPending: Bool
    public let isFailed: Bool
    public let timestamp: Int
    public let memo: String?
    /// Incoming only: the subaddress of this wallet the funds arrived on.
    /// nil for outgoing transactions; see `destinations` for where they went.
    public let recipientAddress: String?
    /// Outgoing destinations in wallet2 order. Empty for incoming
    /// transactions and for outgoing ones wallet2 has no local record of.
    public let destinations: [TransactionDestination]
    /// Subaddress minor indices the transaction touched: the receiving
    /// subaddresses for incoming, the spent-from subaddresses for outgoing.
    public let subaddressIndices: [Int]
    /// wallet2 account (major index) the transaction belongs to.
    public let subaddressAccount: UInt32

    init(transaction: Transaction) {
        uid = transaction.uid
        hash = transaction.hash
        type = transaction.type
        blockHeight = transaction.blockHeight
        amount = transaction.amount
        fee = transaction.fee
        isPending = transaction.isPending
        isFailed = transaction.isFailed
        timestamp = transaction.timestamp
        memo = transaction.note
        recipientAddress = transaction.recipientAddress
        destinations = transaction.destinations
        subaddressIndices = transaction.subaddressIndices
        subaddressAccount = transaction.subaddressAccount
    }
}

public struct BalanceInfo: Equatable {
    // CRITICAL: Use Int64 to prevent overflow on large balances
    public let all: Int64
    public let unlocked: Int64

    init(balance: Balance) {
        all = balance.all
        unlocked = balance.unlocked
    }

    public init(all: Int64, unlocked: Int64) {
        self.all = all
        self.unlocked = unlocked
    }

    public static func == (lhs: BalanceInfo, rhs: BalanceInfo) -> Bool {
        lhs.all == rhs.all && lhs.unlocked == rhs.unlocked
    }
}

public enum SendPriority: Int, CaseIterable {
    case `default`, low, medium, high, last
}

public enum NetworkType: Int32, CaseIterable {
    case mainnet = 0
    case testnet = 1
}

public enum WalletCoreStatus {
    case unknown, ok, error(Error?), critical(Error?)

    init?(_ status: Int32, error: String?) {
        switch status {
        case 0:
            self = .ok
        case 1:
            self = .error(MoneroCoreError.walletStatusError(error))
        case 2:
            self = .critical(MoneroCoreError.walletStatusError(error))
        default:
            return nil
        }
    }
}

public enum WalletState: Equatable {
    case synced
    case connecting(waiting: Bool)
    case syncing(progress: Int, remainingBlocksCount: Int)
    case notSynced(error: WalletStateError)
    case idle(daemonReachable: Bool)

    public static func == (lhs: WalletState, rhs: WalletState) -> Bool {
        switch (lhs, rhs) {
        case (.synced, .synced): return true
        case let (.connecting(lhsWaiting), .connecting(rhsWaiting)): return lhsWaiting == rhsWaiting
        case let (.syncing(lhsProgress, lhsRemaining), .syncing(rhsProgress, rhsRemaining)): return lhsProgress == rhsProgress && lhsRemaining == rhsRemaining
        case let (.notSynced(lhsError), .notSynced(rhsError)): return lhsError == rhsError
        case let (.idle(lhsDaemonReachable), .idle(rhsDaemonReachable)): return lhsDaemonReachable == rhsDaemonReachable
        default: return false
        }
    }

    var description: String {
        switch self {
        case .synced: return "Synced"
        case let .connecting(waiting): return waiting ? "Connecting (waiting)" : "Connecting"
        case let .syncing(progress, remainingBlocksCount): return "Syncing (\(progress)%, remaining blocks: \(remainingBlocksCount))"
        case let .notSynced(error: error): return "Not synced (\(error.description))"
        case let .idle(daemonReachable: daemonReachable): return "Idle daemon (\(daemonReachable ? "reachable" : "unreachable"))"
        }
    }
}

public enum WalletStateError: Error, Equatable {
    case notStarted
    case startError(String?)
    case statusError(String?)

    var description: String {
        switch self {
        case .notStarted: return "Not started"
        case let .startError(message): return "Start error: \(message ?? "No message")"
        case let .statusError(message): return "Status error: \(message ?? "No message")"
        }
    }
}

public enum SendAmount {
    case value(Int)
    case all

    var value: UInt64 {
        switch self {
        case .all: return UInt64(0)
        case let .value(value): return UInt64(value)
        }
    }
}
