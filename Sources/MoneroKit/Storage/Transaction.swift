import Foundation
import GRDB

// enum TransactionStatus: Int, DatabaseValueConvertible, Codable { case new, relayed, invalid }

public enum TransactionType: Int, DatabaseValueConvertible, Codable {
    case incoming = 1
    case outgoing = 2
    case sentToSelf = 3
}

class Transaction: Record {
    var uid: String
    var hash: String
    var type: TransactionType
    var blockHeight: UInt64
    var amount: Int64
    /// Fee in piconero. 0 means unknown (see `knownFee`).
    var fee: UInt64
    var isPending: Bool
    var isFailed: Bool
    var timestamp: Int
    var note: String?
    var recipientAddress: String?
    /// Outgoing destinations as wallet2 reports them
    /// (`TransactionInfo::transfers()`). Empty for incoming transactions
    /// and for outgoing ones this wallet2 cache never built (a wallet
    /// restored from seed): destinations are not on chain. Stored as a
    /// JSON array in a nullable text column; NULL reads back as empty.
    var destinations: [TransactionDestination]
    /// wallet2 subaddress minor indices the transaction touched. Stored
    /// as a JSON array in a nullable text column; NULL reads back as empty.
    var subaddressIndices: [Int]
    /// wallet2 account (major index) the transaction belongs to. NULL
    /// (rows written before the column existed) reads back as 0.
    var subaddressAccount: UInt32

    init(hash: String, type: TransactionType, blockHeight: UInt64, amount: Int64, fee: UInt64, isPending: Bool, isFailed: Bool, timestamp: Int, note: String?, recipientAddress: String?, destinations: [TransactionDestination] = [], subaddressIndices: [Int] = [], subaddressAccount: UInt32 = 0) {
        uid = UUID().uuidString
        self.hash = hash
        self.type = type
        self.blockHeight = blockHeight
        self.amount = amount
        self.fee = Transaction.knownFee(fee)
        self.isPending = isPending
        self.isFailed = isFailed
        self.timestamp = timestamp
        self.note = note
        self.recipientAddress = recipientAddress
        self.destinations = destinations
        self.subaddressIndices = subaddressIndices
        self.subaddressAccount = subaddressAccount

        super.init()
    }

    convenience init(timestamp: Int? = nil) {
        self.init(hash: "", type: .outgoing, blockHeight: 0, amount: 0, fee: 0, isPending: true, isFailed: false, timestamp: timestamp ?? Int(Date().timeIntervalSince1970), note: nil, recipientAddress: nil)
    }

    override open class var databaseTableName: String {
        "transactions"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case uid
        case hash
        case type
        case blockHeight
        case amount
        case fee
        case isPending
        case isFailed
        case timestamp
        case note
        case recipientAddress
        case destinations
        case subaddressIndices
        case subaddressAccount
    }

    required init(row: Row) throws {
        uid = row[Columns.uid]
        hash = row[Columns.hash]
        type = row[Columns.type]
        blockHeight = row[Columns.blockHeight]
        amount = row[Columns.amount]
        fee = row[Columns.fee]
        isPending = row[Columns.isPending]
        isFailed = row[Columns.isFailed]
        timestamp = row[Columns.timestamp]
        note = row[Columns.note]
        recipientAddress = row[Columns.recipientAddress]
        destinations = Transaction.decodeJSON([TransactionDestination].self, from: row[Columns.destinations]) ?? []
        subaddressIndices = Transaction.decodeJSON([Int].self, from: row[Columns.subaddressIndices]) ?? []
        subaddressAccount = (row[Columns.subaddressAccount] as UInt32?) ?? 0

        try super.init(row: row)
    }

    /// wallet2 computes a fee as inputs minus outputs in unsigned
    /// arithmetic, and it counts only the inputs this wallet owns and has
    /// key images for. When a pre-RingCT (version 1) transaction has other
    /// inputs (every payment from another wallet, and in a view-only
    /// wallet its own spends too), the result wraps to just under 2^64.
    /// Real fees stay far below Int64.max (9.2 million XMR), so a larger
    /// value means an unknown fee, which this model stores as 0.
    static func knownFee(_ fee: UInt64) -> UInt64 {
        fee > UInt64(Int64.max) ? 0 : fee
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.uid] = uid
        container[Columns.hash] = hash
        container[Columns.type] = type
        // SQLite integers are signed 64-bit. GRDB traps on a UInt64 above
        // Int64.max, and a trap goes straight through the `try?` around
        // the write. Real heights stay far below that limit, so clamping
        // keeps their order.
        container[Columns.blockHeight] = Int64(clamping: blockHeight)
        container[Columns.amount] = amount
        container[Columns.fee] = Int64(Transaction.knownFee(fee))
        container[Columns.isPending] = isPending
        container[Columns.isFailed] = isFailed
        container[Columns.timestamp] = timestamp
        container[Columns.note] = note
        container[Columns.recipientAddress] = recipientAddress
        container[Columns.destinations] = destinations.isEmpty ? nil : Transaction.encodeJSON(destinations)
        container[Columns.subaddressIndices] = subaddressIndices.isEmpty ? nil : Transaction.encodeJSON(subaddressIndices)
        container[Columns.subaddressAccount] = subaddressAccount
    }

    // MARK: - JSON columns

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
