import Foundation
import GRDB

class Balance: Record {
    var id: String = "single-row-id"
    var all: Int
    var unlocked: Int

    init(all: Int, unlocked: Int) {
        self.all = all
        self.unlocked = unlocked

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
        all = row[Columns.all]
        unlocked = row[Columns.unlocked]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.all] = all
        container[Columns.unlocked] = unlocked
        container[Columns.id] = id
    }
}
