import Foundation
import GRDB

public class SubAddress: Record {
    public var address: String
    public var index: Int
    public var transactionsCount: Int

    init(address: String, index: Int, transactionsCount: Int = 0) {
        self.address = address
        self.index = index
        self.transactionsCount = transactionsCount

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

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.address] = address
        container[Columns.index] = index
        container[Columns.transactionsCount] = transactionsCount
    }
}
