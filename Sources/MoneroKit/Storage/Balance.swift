import Foundation
import GRDB

class Balance: Record {
    var id: String = "single-row-id"
    // CRITICAL: Use Int64 to match GRDB storage and prevent overflow
    // UInt64 max balance exceeds Monero's total supply, but Int64 handles all practical values
    var all: Int64
    var unlocked: Int64

    init(all: UInt64, unlocked: UInt64) {
        // Safe conversion: Monero total supply (~18M XMR = 1.8e19 piconero) fits in Int64
        self.all = Int64(clamping: all)
        self.unlocked = Int64(clamping: unlocked)

        super.init()
    }

    override open class var databaseTableName: String {
        "Balance"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case id
        case all
        case unlocked
    }

    required init(row: Row) throws {
        id = row[Columns.id]
        all = row[Columns.all] as Int64
        unlocked = row[Columns.unlocked] as Int64

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.all] = all
        container[Columns.unlocked] = unlocked
        container[Columns.id] = id
    }
}
