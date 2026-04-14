import Foundation
import GRDB

public class SubAddress: Record {
    public var address: String
    public var index: Int
    public var transactionsCount: Int
    /// Transient user-defined label sourced from wallet2's `.keys` cache.
    /// Not persisted in GRDB — wallet2 is the source of truth.
    public var label: String

    init(address: String, index: Int, transactionsCount: Int = 0, label: String = "") {
        self.address = address
        self.index = index
        self.transactionsCount = transactionsCount
        self.label = label

        super.init()
    }

    override open class var databaseTableName: String {
        "SubAddresss"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case address
        case index
        case transactionsCount
    }

    required init(row: Row) throws {
        address = row[Columns.address]
        index = row[Columns.index]
        transactionsCount = row[Columns.transactionsCount]
        label = ""

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.address] = address
        container[Columns.index] = index
        container[Columns.transactionsCount] = transactionsCount
    }
}
