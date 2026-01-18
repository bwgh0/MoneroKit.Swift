import Foundation
import GRDB

class GrdbStorage {
    var dbPool: DatabasePool

    init(databaseFilePath: String) {
        dbPool = try! DatabasePool(path: databaseFilePath)

        try? migrator.migrate(dbPool)
    }

    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createTransactions") { db in
            try db.create(table: Transaction.databaseTableName) { t in
                t.column(Transaction.Columns.uid.name, .text).notNull()
                t.column(Transaction.Columns.hash.name, .text).notNull()
                t.column(Transaction.Columns.type.name, .integer).notNull()
                t.column(Transaction.Columns.blockHeight.name, .integer).notNull()
                t.column(Transaction.Columns.amount.name, .integer).notNull()
                t.column(Transaction.Columns.fee.name, .integer).notNull()
                t.column(Transaction.Columns.isPending.name, .boolean).notNull()
                t.column(Transaction.Columns.isFailed.name, .boolean).notNull()
                t.column(Transaction.Columns.timestamp.name, .integer).notNull()
                t.column(Transaction.Columns.recipientAddress.name, .text)

                t.primaryKey([Transaction.Columns.hash.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createSubAddresses") { db in
            try db.create(table: SubAddress.databaseTableName) { t in
                t.column(SubAddress.Columns.address.name, .text).notNull()

                t.primaryKey([SubAddress.Columns.address.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createBlockHeifhts") { db in
            try db.create(table: BlockHeights.databaseTableName) { t in
                t.column(BlockHeights.Columns.id.name, .text).notNull()
                t.column(BlockHeights.Columns.daemonHeight.name, .text).notNull()
                t.column(BlockHeights.Columns.walletHeight.name, .text).notNull()

                t.primaryKey([BlockHeights.Columns.id.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("addIndexToSubAddress") { db in
            try db.drop(table: SubAddress.databaseTableName)

            try db.create(table: SubAddress.databaseTableName) { t in
                t.column(SubAddress.Columns.address.name, .text).notNull()
                t.column(SubAddress.Columns.index.name, .integer).notNull()
                t.column(SubAddress.Columns.transactionsCount.name, .integer).notNull()

                t.primaryKey([SubAddress.Columns.address.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("addNoteToTransactions") { db in
            try db.alter(table: Transaction.databaseTableName) { t in
                t.add(column: Transaction.Columns.note.name, .text)
            }
        }

        migrator.registerMigration("createBalance") { db in
            try db.create(table: Balance.databaseTableName) { t in
                t.column(Balance.Columns.id.name, .text).notNull()
                t.column(Balance.Columns.all.name, .text).notNull()
                t.column(Balance.Columns.unlocked.name, .text).notNull()

                t.primaryKey([Balance.Columns.id.name], onConflict: .replace)
            }
        }

        return migrator
    }

    func transaction(byHash: String) -> Transaction? {
        try! dbPool.read { db in
            try Transaction.filter(Transaction.Columns.hash == byHash).fetchOne(db)
        }
    }

    func transactions(fromTimestamp: Int?, descending: Bool, type: TransactionFilterType?, limit: Int?) -> [Transaction] {
        try! dbPool.read { db in
            var query = Transaction.order(descending ? Transaction.Columns.timestamp.desc : Transaction.Columns.timestamp.asc)

            if let fromTimestamp {
                query = query.filter(descending ? Transaction.Columns.timestamp < fromTimestamp : Transaction.Columns.timestamp > fromTimestamp)
            }

            if let type {
                query = query.filter(type.types.contains(Transaction.Columns.type))
            }

            if let limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db)
        }
    }

    func update(transactions: [Transaction]) {
        try! dbPool.write { db in
            try Transaction.deleteAll(db)

            for transaction in transactions {
                try transaction.insert(db)
            }
        }
    }

    func update(subAddresses: [SubAddress]) {
        try! dbPool.write { db in
            try SubAddress.deleteAll(db)
            for subAddress in subAddresses {
                try subAddress.insert(db)
            }
        }
    }

    func add(subAddress: SubAddress) {
        try! dbPool.write { db in
            try subAddress.insert(db)
        }
    }

    func update(balance: Balance) {
        try! dbPool.write { db in
            try Balance.deleteAll(db)
            try balance.insert(db)
        }
    }

    func update(blockHeights: BlockHeights) {
        try! dbPool.write { db in
            try BlockHeights.deleteAll(db)
            try blockHeights.insert(db)
        }
    }

    func addressExists(_ address: String) -> Bool {
        try! dbPool.read { db in
            try SubAddress.filter(SubAddress.Columns.address == address).fetchOne(db) != nil
        }
    }

    func setAddressTransactionsCount(index: Int, txCount: Int) {
        _ = try! dbPool.write { db in
            try SubAddress.filter(SubAddress.Columns.index == index).updateAll(db, [SubAddress.Columns.transactionsCount.set(to: txCount)])
        }
    }

    func getLastUnusedAddress() -> SubAddress? {
        try! dbPool.read { db in
            try SubAddress.filter(SubAddress.Columns.transactionsCount == 0).order(SubAddress.Columns.index.desc).fetchOne(db)
        }
    }

    func getAddress(index: Int) -> SubAddress? {
        try! dbPool.read { db in
            try SubAddress.filter(SubAddress.Columns.index == index).fetchOne(db)
        }
    }

    func getAllAddresses() -> [SubAddress] {
        try! dbPool.read { db in
            try SubAddress.order(SubAddress.Columns.index.asc).fetchAll(db)
        }
    }

    func getBalance() -> Balance? {
        try! dbPool.read { db in
            try Balance.fetchOne(db)
        }
    }

    func getBlockHeights() -> BlockHeights? {
        try! dbPool.read { db in
            try BlockHeights.fetchOne(db)
        }
    }
}
