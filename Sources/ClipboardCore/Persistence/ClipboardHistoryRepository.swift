import Foundation
import SQLite3

public enum ClipboardHistoryFilter: String, CaseIterable, Codable, Sendable {
    case all
    case text
    case code
    case links
    case images
    case files
    case pinned
}

public struct ClipboardHistoryRetention: Equatable, Sendable {
    public static let `default` = ClipboardHistoryRetention()

    public let maximumUnpinnedItems: Int
    public let maximumUnpinnedAge: TimeInterval

    public init(
        maximumUnpinnedItems: Int = 1_000,
        maximumUnpinnedAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.maximumUnpinnedItems = max(0, maximumUnpinnedItems)
        self.maximumUnpinnedAge = max(0, maximumUnpinnedAge)
    }
}

public enum ClipboardHistoryRepositoryError: Error, Equatable, Sendable {
    case databaseUnavailable
    case openFailed
    case unsupportedSchemaVersion
    case migrationFailed
    case invalidPayload
    /// The selected item exists, but its external payload is missing, unsafe, or corrupt.
    case payloadUnavailable
    case operationFailed
}

/// SQLite-backed clipboard history. The actor keeps database work away from the
/// main actor, and normal list/search calls intentionally return metadata-only rows.
public actor ClipboardHistoryRepository {
    private static let schemaVersion: Int32 = 2
    private static let metadataSearchPreviewLength = 1_024

    private let databaseURL: URL
    private var retention: ClipboardHistoryRetention
    private let blobStore: ClipboardBlobStore
    private let largePayloadThreshold: Int
    private var database: OpaquePointer?
#if DEBUG
    /// Test-only cancellation seam for the synchronous record transaction.
    private let recordCommitHookStorage = RecordCommitHookStorage()

    internal nonisolated var recordBeforeCommitHook: (@Sendable () -> Void)? {
        get { recordCommitHookStorage.current }
        set { recordCommitHookStorage.current = newValue }
    }
#endif

    public init(
        databaseURL: URL,
        retention: ClipboardHistoryRetention = .default,
        largePayloadThreshold: Int = 64 * 1024
    ) {
        self.databaseURL = databaseURL
        self.retention = retention
        self.blobStore = ClipboardBlobStore(databaseURL: databaseURL)
        self.largePayloadThreshold = max(0, largePayloadThreshold)
    }

    /// Creates the database and applies migrations. Initializing the repository does
    /// no file or database I/O, so callers can create it during app setup safely.
    public func open() throws {
        guard database == nil else {
            return
        }

        do {
            try createParentDirectoryIfNeeded()
        } catch {
            throw ClipboardHistoryRepositoryError.openFailed
        }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            if let connection {
                sqlite3_close_v2(connection)
            }
            throw ClipboardHistoryRepositoryError.openFailed
        }

        sqlite3_busy_timeout(connection, 1_000)
        database = connection
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            try migrateIfNeeded()
            try enforceRetention(now: Date())
            cleanupOrphanedBlobs()
        } catch let error as ClipboardHistoryRepositoryError {
            closeConnection()
            throw error
        } catch {
            closeConnection()
            throw ClipboardHistoryRepositoryError.openFailed
        }
    }

    public func close() {
        closeConnection()
    }

    @discardableResult
    public func record(_ item: ClipboardItem, now: Date = Date()) throws -> ClipboardItem {
        try Task.checkCancellation()
        guard let payload = item.payload else {
            throw ClipboardHistoryRepositoryError.invalidPayload
        }
        try Task.checkCancellation()
        let payloadData: Data
        let metadataData: Data
        do {
            payloadData = try JSONEncoder().encode(payload)
            metadataData = try JSONEncoder().encode(item.payloadMetadata)
        } catch {
            throw ClipboardHistoryRepositoryError.invalidPayload
        }
        try Task.checkCancellation()

        let urlText = payload.url?.absoluteString
        let domain = payload.url?.host
        let metadataSearchText = item.payloadMetadata.availableTypeIdentifiers.joined(separator: " ")

        var stagedReferences: [String] = []
        do {
            let stored = try transaction({
                let existing = try existingRow(contentHash: item.contentHash)
                let stored: ClipboardItem
                if let existing, item.lastUsedAt >= existing.lastUsedAt {
                    let storage = try preparePayload(payloadData)
                    if let reference = storage.reference {
                        stagedReferences.append(reference)
                    }
                    let lastUsedAt = item.lastUsedAt
                    try updateRow(
                        id: existing.id,
                        item: item,
                        createdAt: existing.createdAt,
                        lastUsedAt: lastUsedAt,
                        isPinned: existing.isPinned,
                        payloadData: storage.databaseData,
                        metadataData: metadataData,
                        blobReference: storage.reference,
                        urlText: urlText,
                        domain: domain,
                        metadataSearchText: metadataSearchText
                    )
                    stored = itemWithBlobReference(
                        item,
                        id: existing.id,
                        createdAt: existing.createdAt,
                        lastUsedAt: lastUsedAt,
                        isPinned: existing.isPinned,
                        reference: storage.reference
                    )
                } else if let existing {
                    guard let existingItem = try hydratedItem(id: existing.id) else {
                        throw ClipboardHistoryRepositoryError.operationFailed
                    }
                    stored = existingItem
                } else {
                    let storage = try preparePayload(payloadData)
                    if let reference = storage.reference {
                        stagedReferences.append(reference)
                    }
                    try insertRow(
                        item: item,
                        payloadData: storage.databaseData,
                        metadataData: metadataData,
                        blobReference: storage.reference,
                        urlText: urlText,
                        domain: domain,
                        metadataSearchText: metadataSearchText
                    )
                    stored = itemWithBlobReference(item, reference: storage.reference)
                }
                try enforceRetentionInTransaction(now: now)
                return stored
            }, beforeCommit: {
#if DEBUG
                if let hook = self.recordCommitHookStorage.take() {
                    hook()
                }
#endif
                try Task.checkCancellation()
            })
            cleanupOrphanedBlobs()
            return stored
        } catch {
            for reference in stagedReferences {
                blobStore.remove(reference)
            }
            if error is CancellationError {
                throw error
            }
            if let repositoryError = error as? ClipboardHistoryRepositoryError {
                throw repositoryError
            }
            throw ClipboardHistoryRepositoryError.operationFailed
        }
    }

    public func history(
        query: String = "",
        filter: ClipboardHistoryFilter = .all,
        limit: Int? = nil
    ) throws -> [ClipboardItem] {
        guard limit.map({ $0 > 0 }) ?? true else {
            return []
        }
        let database = try requiredDatabase()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        var joins = ""

        if let ftsQuery = literalFTSQuery(for: trimmedQuery) {
            joins = " JOIN clipboard_items_fts ON clipboard_items_fts.rowid = clipboard_items.rowid"
            conditions.append("clipboard_items_fts MATCH ?")
            bindings.append(.text(ftsQuery))
        } else if !trimmedQuery.isEmpty {
            conditions.append("0")
        }
        switch filter {
        case .all:
            break
        case .pinned:
            conditions.append("clipboard_items.is_pinned = 1")
        case .links:
            conditions.append("clipboard_items.primary_type = ?")
            bindings.append(.text(ClipboardPrimaryType.url.rawValue))
        case .text, .code, .images, .files:
            conditions.append("clipboard_items.primary_type = ?")
            bindings.append(.text(primaryType(for: filter).rawValue))
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let limitClause = limit.map { _ in " LIMIT ?" } ?? ""
        if let limit {
            bindings.append(.int(limit))
        }
        let sql = """
        SELECT clipboard_items.id, clipboard_items.content_hash, clipboard_items.primary_type,
               substr(CAST(clipboard_items.searchable_text AS BLOB), 1, \(Self.metadataSearchPreviewLength)), clipboard_items.source_app_name,
               clipboard_items.source_bundle_id, clipboard_items.created_at,
               clipboard_items.last_used_at, clipboard_items.is_pinned,
               clipboard_items.byte_size, clipboard_items.payload_metadata_json,
               clipboard_items.payload_blob_reference
        FROM clipboard_items\(joins)\(whereClause)
        ORDER BY clipboard_items.last_used_at DESC, clipboard_items.created_at DESC, clipboard_items.id ASC\(limitClause)
        """

        return try withStatement(database, sql) { statement in
            try bind(bindings, to: statement)
            var rows: [ClipboardItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try metadataItem(from: statement, searchableTextIsBlob: true))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            return rows
        }
    }

    public func item(id: UUID) throws -> ClipboardItem? {
        let database = try requiredDatabase()
        let sql = """
        SELECT id, content_hash, primary_type, searchable_text, source_app_name,
               source_bundle_id, created_at, last_used_at, is_pinned, byte_size,
               payload_metadata_json, payload_blob_reference, payload_json
        FROM clipboard_items WHERE id = ?
        """
        return try withStatement(database, sql) { statement in
            try bind([.text(id.uuidString)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                guard sqlite3_errcode(database) == SQLITE_DONE else {
                    throw ClipboardHistoryRepositoryError.operationFailed
                }
                return nil
            }
            return try hydratedItem(from: statement)
        }
    }

    /// Records a successful clipboard restore without replacing the saved payload
    /// or capture metadata. A newer timestamp already stored for the item wins.
    @discardableResult
    public func markUsed(id: UUID, at date: Date = Date()) throws -> Bool {
        let changed = try transaction {
            let database = try requiredDatabase()
            try withStatement(
                database,
                "UPDATE clipboard_items SET last_used_at = MAX(last_used_at, ?) WHERE id = ?"
            ) { statement in
                try bind([.double(date.timeIntervalSinceReferenceDate), .text(id.uuidString)], to: statement)
                try stepDone(statement, database: database)
            }
            guard sqlite3_changes(database) > 0 else {
                return false
            }
            try enforceRetentionInTransaction(now: date)
            return true
        }
        if changed {
            cleanupOrphanedBlobs()
        }
        return changed
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, for id: UUID, now: Date = Date()) throws -> ClipboardItem? {
        let result: ClipboardItem? = try transaction {
            let database = try requiredDatabase()
            try withStatement(database, "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?") { statement in
                try bind([.int(pinned ? 1 : 0), .text(id.uuidString)], to: statement)
                try stepDone(statement, database: database)
            }
            guard sqlite3_changes(database) > 0 else {
                return nil
            }
            if !pinned {
                try enforceRetentionInTransaction(now: now)
            }
            return try metadataItem(id: id)
        }
        cleanupOrphanedBlobs()
        return result
    }

    public func delete(id: UUID) throws {
        let database = try requiredDatabase()
        try transaction {
            try withStatement(database, "DELETE FROM clipboard_items WHERE id = ?") { statement in
                try bind([.text(id.uuidString)], to: statement)
                try stepDone(statement, database: database)
            }
        }
        cleanupOrphanedBlobs()
    }

    public func clear(keepingPinned: Bool = false) throws {
        let database = try requiredDatabase()
        let sql = keepingPinned ? "DELETE FROM clipboard_items WHERE is_pinned = 0" : "DELETE FROM clipboard_items"
        try transaction {
            try execute(sql, database: database)
        }
        cleanupOrphanedBlobs()
    }

    public func enforceRetention(now: Date = Date()) throws {
        try transaction {
            try enforceRetentionInTransaction(now: now)
        }
        cleanupOrphanedBlobs()
    }

    /// Replaces the active retention policy and applies it in the same database transaction.
    /// Pinned rows are never removed by this operation.
    public func updateRetention(_ policy: ClipboardHistoryRetention, now: Date = Date()) throws {
        let previous = retention
        do {
            try transaction {
                try enforceRetentionInTransaction(policy: policy, now: now)
            }
            retention = policy
            cleanupOrphanedBlobs()
        } catch {
            retention = previous
            throw error
        }
    }

    isolated deinit {
        closeConnection()
    }

    private func createParentDirectoryIfNeeded() throws {
        let parent = databaseURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ClipboardHistoryRepositoryError.openFailed
            }
            return
        }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func migrateIfNeeded() throws {
        let database = try requiredDatabase()
        let version = try userVersion(database: database)
        if version > Self.schemaVersion {
            throw ClipboardHistoryRepositoryError.unsupportedSchemaVersion
        }
        guard version < Self.schemaVersion else {
            return
        }
        var stagedReferences: [String] = []
        do {
            try transaction {
                var currentVersion = version
                if version == 0 {
                    try createVersionOneSchema(database: database)
                    try execute("PRAGMA user_version = 1", database: database)
                    currentVersion = 1
                }
                if currentVersion == 1 {
                    try migrateVersionOneToTwo(database: database, stagedReferences: &stagedReferences)
                    try execute("PRAGMA user_version = 2", database: database)
                    currentVersion = 2
                }
                guard currentVersion == Self.schemaVersion else {
                    throw ClipboardHistoryRepositoryError.migrationFailed
                }
            }
        } catch {
            for reference in stagedReferences {
                blobStore.remove(reference)
            }
            throw ClipboardHistoryRepositoryError.migrationFailed
        }
    }

    private func migrateVersionOneToTwo(
        database: OpaquePointer,
        stagedReferences: inout [String]
    ) throws {
        let ids: [UUID] = try withStatement(
            database,
            "SELECT id FROM clipboard_items"
        ) { statement in
            var ids: [UUID] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = columnText(statement, 0),
                      let id = UUID(uuidString: idText) else {
                    throw ClipboardHistoryRepositoryError.migrationFailed
                }
                ids.append(id)
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw ClipboardHistoryRepositoryError.migrationFailed
            }
            return ids
        }

        for id in ids {
            let payloadData: Data = try withStatement(
                database,
                "SELECT payload_json FROM clipboard_items WHERE id = ?"
            ) { statement in
                try bind([.text(id.uuidString)], to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW, let data = columnData(statement, 0) else {
                    throw ClipboardHistoryRepositoryError.migrationFailed
                }
                return data
            }
            guard payloadData.count > largePayloadThreshold else {
                continue
            }
            let reference = try blobStore.stage(payloadData)
            stagedReferences.append(reference)
            try withStatement(
                database,
                "UPDATE clipboard_items SET payload_blob_reference = ?, payload_json = ? WHERE id = ?"
            ) { statement in
                try bind([.text(reference), .data(Data()), .text(id.uuidString)], to: statement)
                try stepDone(statement, database: database)
            }
        }
    }

    private func createVersionOneSchema(database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE clipboard_items (
                id TEXT PRIMARY KEY NOT NULL,
                content_hash TEXT UNIQUE NOT NULL,
                primary_type TEXT NOT NULL,
                searchable_text TEXT,
                source_app_name TEXT,
                source_bundle_id TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL,
                byte_size INTEGER NOT NULL,
                payload_metadata_json BLOB NOT NULL,
                payload_blob_reference TEXT,
                payload_json BLOB NOT NULL,
                search_url TEXT,
                search_domain TEXT,
                search_metadata TEXT NOT NULL
            )
            """,
            database: database
        )
        try execute(
            """
            CREATE VIRTUAL TABLE clipboard_items_fts USING fts5(
                searchable_text, search_url, search_domain, source_app_name,
                source_bundle_id, search_metadata,
                content='clipboard_items', content_rowid='rowid'
            )
            """,
            database: database
        )
        try execute(
            """
            CREATE TRIGGER clipboard_items_ai AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clipboard_items_fts(rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
                VALUES (new.rowid, new.searchable_text, new.search_url, new.search_domain, new.source_app_name, new.source_bundle_id, new.search_metadata);
            END
            """,
            database: database
        )
        try execute(
            """
            CREATE TRIGGER clipboard_items_ad AFTER DELETE ON clipboard_items BEGIN
                INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
                VALUES ('delete', old.rowid, old.searchable_text, old.search_url, old.search_domain, old.source_app_name, old.source_bundle_id, old.search_metadata);
            END
            """,
            database: database
        )
        try execute(
            """
            CREATE TRIGGER clipboard_items_au AFTER UPDATE ON clipboard_items BEGIN
                INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
                VALUES ('delete', old.rowid, old.searchable_text, old.search_url, old.search_domain, old.source_app_name, old.source_bundle_id, old.search_metadata);
                INSERT INTO clipboard_items_fts(rowid, searchable_text, search_url, search_domain, source_app_name, source_bundle_id, search_metadata)
                VALUES (new.rowid, new.searchable_text, new.search_url, new.search_domain, new.source_app_name, new.source_bundle_id, new.search_metadata);
            END
            """,
            database: database
        )
    }

    private func existingRow(contentHash: String) throws -> ExistingRow? {
        let database = try requiredDatabase()
        return try withStatement(database, "SELECT id, created_at, last_used_at, is_pinned, payload_blob_reference FROM clipboard_items WHERE content_hash = ?") { statement in
            try bind([.text(contentHash)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                guard sqlite3_errcode(database) == SQLITE_DONE else {
                    throw ClipboardHistoryRepositoryError.operationFailed
                }
                return nil
            }
            guard let idText = columnText(statement, 0), let id = UUID(uuidString: idText) else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            return ExistingRow(
                id: id,
                createdAt: dateColumn(statement, 1),
                lastUsedAt: dateColumn(statement, 2),
                isPinned: sqlite3_column_int(statement, 3) != 0,
                payloadBlobReference: columnText(statement, 4)
            )
        }
    }

    private func insertRow(
        item: ClipboardItem,
        payloadData: Data,
        metadataData: Data,
        blobReference: String?,
        urlText: String?,
        domain: String?,
        metadataSearchText: String
    ) throws {
        let database = try requiredDatabase()
        let sql = """
        INSERT INTO clipboard_items (
            id, content_hash, primary_type, searchable_text, source_app_name,
            source_bundle_id, created_at, last_used_at, is_pinned, byte_size,
            payload_metadata_json, payload_blob_reference, payload_json, search_url,
            search_domain, search_metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(database, sql) { statement in
            try bind(itemBindings(
                id: item.id,
                item: item,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: item.isPinned,
                payloadData: payloadData,
                metadataData: metadataData,
                blobReference: blobReference,
                urlText: urlText,
                domain: domain,
                metadataSearchText: metadataSearchText
            ), to: statement)
            try stepDone(statement, database: database)
        }
    }

    private func updateRow(
        id: UUID,
        item: ClipboardItem,
        createdAt: Date,
        lastUsedAt: Date,
        isPinned: Bool,
        payloadData: Data,
        metadataData: Data,
        blobReference: String?,
        urlText: String?,
        domain: String?,
        metadataSearchText: String
    ) throws {
        let database = try requiredDatabase()
        let sql = """
        UPDATE clipboard_items SET content_hash = ?, primary_type = ?, searchable_text = ?,
        source_app_name = ?, source_bundle_id = ?, created_at = ?, last_used_at = ?,
        is_pinned = ?, byte_size = ?, payload_metadata_json = ?, payload_blob_reference = ?,
        payload_json = ?, search_url = ?, search_domain = ?, search_metadata = ? WHERE id = ?
        """
        try withStatement(database, sql) { statement in
            var values = itemBindings(
                id: id,
                item: item,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                isPinned: isPinned,
                payloadData: payloadData,
                metadataData: metadataData,
                blobReference: blobReference,
                urlText: urlText,
                domain: domain,
                metadataSearchText: metadataSearchText
            )
            values.removeFirst()
            values.append(.text(id.uuidString))
            try bind(values, to: statement)
            try stepDone(statement, database: database)
        }
    }

    private func itemBindings(
        id: UUID,
        item: ClipboardItem,
        createdAt: Date,
        lastUsedAt: Date,
        isPinned: Bool,
        payloadData: Data,
        metadataData: Data,
        blobReference: String?,
        urlText: String?,
        domain: String?,
        metadataSearchText: String
    ) -> [SQLiteValue] {
        [
            .text(id.uuidString), .text(item.contentHash), .text(item.primaryType.rawValue),
            .text(item.searchableText), .text(item.sourceAppName), .text(item.sourceBundleID),
            .double(createdAt.timeIntervalSinceReferenceDate), .double(lastUsedAt.timeIntervalSinceReferenceDate),
            .int(isPinned ? 1 : 0), .int(item.byteSize), .data(metadataData), .text(blobReference),
            .data(payloadData), .text(urlText), .text(domain), .text(metadataSearchText)
        ]
    }

    private func preparePayload(_ payloadData: Data) throws -> PreparedPayload {
        guard payloadData.count > largePayloadThreshold else {
            return PreparedPayload(databaseData: payloadData, reference: nil)
        }
        let reference = try blobStore.stage(payloadData)
        return PreparedPayload(databaseData: Data(), reference: reference)
    }

    private func itemWithBlobReference(
        _ item: ClipboardItem,
        id: UUID? = nil,
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        isPinned: Bool? = nil,
        reference: String?
    ) -> ClipboardItem {
        ClipboardItem(
            id: id ?? item.id,
            contentHash: item.contentHash,
            primaryType: item.primaryType,
            searchableText: item.searchableText,
            sourceAppName: item.sourceAppName,
            sourceBundleID: item.sourceBundleID,
            createdAt: createdAt ?? item.createdAt,
            lastUsedAt: lastUsedAt ?? item.lastUsedAt,
            isPinned: isPinned ?? item.isPinned,
            byteSize: item.byteSize,
            payloadMetadata: item.payloadMetadata,
            payloadBlobReference: reference,
            payload: item.payload
        )
    }

    private func enforceRetentionInTransaction(now: Date) throws {
        try enforceRetentionInTransaction(policy: retention, now: now)
    }

    private func enforceRetentionInTransaction(
        policy: ClipboardHistoryRetention,
        now: Date
    ) throws {
        let database = try requiredDatabase()
        let cutoff = now.timeIntervalSinceReferenceDate - policy.maximumUnpinnedAge
        try withStatement(database, "DELETE FROM clipboard_items WHERE is_pinned = 0 AND last_used_at < ?") { statement in
            try bind([.double(cutoff)], to: statement)
            try stepDone(statement, database: database)
        }
        try withStatement(
            database,
            "DELETE FROM clipboard_items WHERE id IN (SELECT id FROM clipboard_items WHERE is_pinned = 0 ORDER BY last_used_at DESC, created_at DESC, id ASC LIMIT -1 OFFSET ?)"
        ) { statement in
            try bind([.int(policy.maximumUnpinnedItems)], to: statement)
            try stepDone(statement, database: database)
        }
    }

    private func metadataItem(id: UUID) throws -> ClipboardItem? {
        let database = try requiredDatabase()
        return try withStatement(
            database,
            "SELECT id, content_hash, primary_type, searchable_text, source_app_name, source_bundle_id, created_at, last_used_at, is_pinned, byte_size, payload_metadata_json, payload_blob_reference FROM clipboard_items WHERE id = ?"
        ) { statement in
            try bind([.text(id.uuidString)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                guard sqlite3_errcode(database) == SQLITE_DONE else {
                    throw ClipboardHistoryRepositoryError.operationFailed
                }
                return nil
            }
            return try metadataItem(from: statement)
        }
    }

    private func hydratedItem(id: UUID) throws -> ClipboardItem? {
        let database = try requiredDatabase()
        return try withStatement(
            database,
            "SELECT id, content_hash, primary_type, searchable_text, source_app_name, source_bundle_id, created_at, last_used_at, is_pinned, byte_size, payload_metadata_json, payload_blob_reference, payload_json FROM clipboard_items WHERE id = ?"
        ) { statement in
            try bind([.text(id.uuidString)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                guard sqlite3_errcode(database) == SQLITE_DONE else {
                    throw ClipboardHistoryRepositoryError.operationFailed
                }
                return nil
            }
            return try hydratedItem(from: statement)
        }
    }

    private func metadataItem(
        from statement: OpaquePointer,
        searchableTextIsBlob: Bool = false
    ) throws -> ClipboardItem {
        guard
            let idText = columnText(statement, 0), let id = UUID(uuidString: idText),
            let contentHash = columnText(statement, 1),
            let typeText = columnText(statement, 2), let primaryType = ClipboardPrimaryType(rawValue: typeText),
            let metadataData = columnData(statement, 10)
        else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        let metadata: ClipboardPayloadMetadata
        do {
            metadata = try JSONDecoder().decode(ClipboardPayloadMetadata.self, from: metadataData)
        } catch {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        return ClipboardItem(
            id: id,
            contentHash: contentHash,
            primaryType: primaryType,
            searchableText: searchableTextIsBlob ? stringColumnData(statement, 3) : columnText(statement, 3),
            sourceAppName: columnText(statement, 4),
            sourceBundleID: columnText(statement, 5),
            createdAt: dateColumn(statement, 6),
            lastUsedAt: dateColumn(statement, 7),
            isPinned: sqlite3_column_int(statement, 8) != 0,
            byteSize: Int(sqlite3_column_int64(statement, 9)),
            payloadMetadata: metadata,
            payloadBlobReference: columnText(statement, 11),
            payload: nil
        )
    }

    private func hydratedItem(from statement: OpaquePointer) throws -> ClipboardItem {
        let metadata = try metadataItem(from: statement)
        let payloadData: Data
        if let reference = metadata.payloadBlobReference {
            do {
                payloadData = try blobStore.read(reference)
            } catch {
                throw ClipboardHistoryRepositoryError.payloadUnavailable
            }
        } else {
            guard let inlinePayloadData = columnData(statement, 12) else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            payloadData = inlinePayloadData
        }
        do {
            let payload = try JSONDecoder().decode(ClipboardPayload.self, from: payloadData)
            if ClipboardHasher.identity(for: payload) != metadata.contentHash {
                throw ClipboardHistoryRepositoryError.payloadUnavailable
            }
            return ClipboardItem(
                id: metadata.id,
                contentHash: metadata.contentHash,
                primaryType: metadata.primaryType,
                searchableText: metadata.searchableText,
                sourceAppName: metadata.sourceAppName,
                sourceBundleID: metadata.sourceBundleID,
                createdAt: metadata.createdAt,
                lastUsedAt: metadata.lastUsedAt,
                isPinned: metadata.isPinned,
                byteSize: metadata.byteSize,
                payloadMetadata: metadata.payloadMetadata,
                payloadBlobReference: metadata.payloadBlobReference,
                payload: payload
            )
        } catch let error as ClipboardHistoryRepositoryError {
            throw error
        } catch {
            throw ClipboardHistoryRepositoryError.payloadUnavailable
        }
    }

    private func cleanupOrphanedBlobs() {
        guard database != nil else {
            return
        }
        guard let references = try? referencedBlobReferences() else {
            return
        }
        try? blobStore.cleanup(keeping: references)
    }

    private func referencedBlobReferences() throws -> Set<String> {
        let database = try requiredDatabase()
        return try withStatement(database, "SELECT payload_blob_reference FROM clipboard_items WHERE payload_blob_reference IS NOT NULL") { statement in
            var references: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let reference = columnText(statement, 0) {
                    references.insert(reference)
                }
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw ClipboardHistoryRepositoryError.operationFailed
            }
            return references
        }
    }

    private func literalFTSQuery(for text: String) -> String? {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !tokens.isEmpty else {
            return nil
        }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    private func primaryType(for filter: ClipboardHistoryFilter) -> ClipboardPrimaryType {
        switch filter {
        case .text: .text
        case .code: .code
        case .links: .url
        case .images: .image
        case .files: .files
        case .all, .pinned: .other
        }
    }

    private func transaction<T>(
        _ operation: () throws -> T,
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> T {
        let database = try requiredDatabase()
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            let value = try operation()
            try beforeCommit?()
            try execute("COMMIT", database: database)
            return value
        } catch {
            _ = try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func requiredDatabase() throws -> OpaquePointer {
        guard let database else {
            throw ClipboardHistoryRepositoryError.databaseUnavailable
        }
        return database
    }

    private func closeConnection() {
        guard let database else {
            return
        }
        sqlite3_close_v2(database)
        self.database = nil
    }
}

private struct ExistingRow {
    let id: UUID
    let createdAt: Date
    let lastUsedAt: Date
    let isPinned: Bool
    let payloadBlobReference: String?
}

private struct PreparedPayload {
    let databaseData: Data
    let reference: String?
}

#if DEBUG
private final class RecordCommitHookStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?

    var current: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hook
        }
        set {
            lock.lock()
            hook = newValue
            lock.unlock()
        }
    }

    func take() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let hook = self.hook
        self.hook = nil
        return hook
    }
}
#endif

private enum SQLiteValue {
    case int(Int)
    case double(Double)
    case text(String?)
    case data(Data)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func withStatement<T>(
    _ database: OpaquePointer,
    _ sql: String,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw ClipboardHistoryRepositoryError.operationFailed
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
}

private func execute(_ sql: String, database: OpaquePointer) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw ClipboardHistoryRepositoryError.operationFailed
    }
}

private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
    for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        let result: Int32
        switch value {
        case .int(let value):
            result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case .double(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            if let value {
                result = value.withCString {
                    sqlite3_bind_text64(statement, index, $0, sqlite3_uint64(value.utf8.count), sqliteTransient, UInt8(SQLITE_UTF8))
                }
            } else {
                result = sqlite3_bind_null(statement, index)
            }
        case .data(let value):
            result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob64(statement, index, bytes.baseAddress, sqlite3_uint64(value.count), sqliteTransient)
            }
        }
        guard result == SQLITE_OK else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
    }
}

private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
    _ = database
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw ClipboardHistoryRepositoryError.operationFailed
    }
}

private func userVersion(database: OpaquePointer) throws -> Int32 {
    try withStatement(database, "PRAGMA user_version") { statement in
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ClipboardHistoryRepositoryError.operationFailed
        }
        return sqlite3_column_int(statement, 0)
    }
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(decoding: Data(bytes: value, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
}

private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    let count = Int(sqlite3_column_bytes(statement, index))
    guard let bytes = sqlite3_column_blob(statement, index) else {
        return count == 0 ? Data() : nil
    }
    return Data(bytes: bytes, count: count)
}

private func stringColumnData(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
        return nil
    }
    guard let data = columnData(statement, index) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}

private func dateColumn(_ statement: OpaquePointer, _ index: Int32) -> Date {
    Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
}
