import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteHistoryStore: @unchecked Sendable {
    public enum InsertResult: Equatable {
        case inserted(ClipboardItem)
        case duplicate
    }

    private struct Migration {
        let version: Int
        let sql: String
    }

    private static let migrations = [
        Migration(version: 1, sql: """
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY NOT NULL,
                content_hash TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                display_text TEXT,
                source_bundle_id TEXT,
                source_application_name TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_screenshot INTEGER NOT NULL DEFAULT 0,
                representations_json TEXT NOT NULL,
                asset_paths_json TEXT NOT NULL,
                preview_asset_path TEXT
            );
            CREATE INDEX IF NOT EXISTS history_created_at ON history(created_at DESC);
            CREATE INDEX IF NOT EXISTS history_pinned ON history(is_pinned);
            """)
    ]

    public let databaseURL: URL
    private let assetStore: AssetStore
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    public init(databaseURL: URL, assetStore: AssetStore, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        self.assetStore = assetStore
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: databaseURL.deletingLastPathComponent().path
        )
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK else {
            let error = databaseError
            if let openedDatabase = database {
                sqlite3_close(openedDatabase)
                database = nil
            }
            throw error
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try migrateSchema()
            try recoverOrphanedAssets()
        } catch {
            if let openedDatabase = database {
                sqlite3_close(openedDatabase)
                database = nil
            }
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    @discardableResult
    public func insert(_ normalized: NormalizedClipboardItem) throws -> InsertResult {
        lock.lock()
        defer { lock.unlock() }
        if try rowExists(contentHash: normalized.item.contentHash) { return .duplicate }

        var storedAssets: [String] = []
        do {
            var item = normalized.item
            for (type, data) in normalized.binaryRepresentations {
                let relativePath = try assetStore.store(data, typeIdentifier: type)
                item.assetPaths[type] = relativePath
                storedAssets.append(relativePath)
            }
            if item.kind == .image,
               let previewType = ClipboardNormalizer.imageTypes.first(where: { normalized.binaryRepresentations[$0] != nil }),
               let previewData = normalized.binaryRepresentations[previewType],
               let previewPath = assetStore.makePreview(from: previewData, contentHash: item.contentHash) {
                item.previewAssetPath = previewPath
                storedAssets.append(previewPath)
            }

            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let statement = try prepare("""
                    INSERT INTO history (
                        id, content_hash, kind, display_text, source_bundle_id,
                        source_application_name, created_at, last_used_at, is_pinned,
                        is_screenshot, representations_json, asset_paths_json, preview_asset_path
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(item.id, at: 1, to: statement)
                try bind(item.contentHash, at: 2, to: statement)
                try bind(item.kind.rawValue, at: 3, to: statement)
                try bind(item.displayText, at: 4, to: statement)
                try bind(item.sourceBundleIdentifier, at: 5, to: statement)
                try bind(item.sourceApplicationName, at: 6, to: statement)
                try bind(item.createdAt.timeIntervalSince1970, at: 7, to: statement)
                try bind(item.createdAt.timeIntervalSince1970, at: 8, to: statement)
                try bind(item.isPinned ? 1 : 0, at: 9, to: statement)
                try bind(item.isScreenshot ? 1 : 0, at: 10, to: statement)
                try bind(try encode(item.representations), at: 11, to: statement)
                try bind(try encode(item.assetPaths), at: 12, to: statement)
                try bind(item.previewAssetPath, at: 13, to: statement)
                try stepDone(statement)
                try execute("COMMIT;")
                return .inserted(item)
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } catch {
            try? removeAssetsIfUnreferenced(storedAssets)
            throw error
        }
    }

    public func allItems(
        search: String = "",
        kind: ClipboardContentKind? = nil,
        pinnedOnly: Bool = false
    ) throws -> [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }
        let items = try queryItems()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if let kind, item.kind != kind { return false }
            if pinnedOnly && !item.isPinned { return false }
            guard !query.isEmpty else { return true }
            return [item.displayText, item.sourceApplicationName, item.sourceBundleIdentifier]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    public func item(id: String) throws -> ClipboardItem? {
        try allItems().first { $0.id == id }
    }

    public func setPinned(_ pinned: Bool, id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE history SET is_pinned = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(pinned ? 1 : 0, at: 1, to: statement)
        try bind(id, at: 2, to: statement)
        try stepDone(statement)
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let item = try queryItems().first(where: { $0.id == id }) else { return false }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("DELETE FROM history WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, to: statement)
            try stepDone(statement)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try removeAssetsIfUnreferenced(assetPaths(for: item))
        return true
    }

    public func clearHistory() throws {
        lock.lock()
        defer { lock.unlock() }
        let items = try queryItems()
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM history;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try assetStore.remove(items.flatMap(assetPaths(for:)))
    }

    @discardableResult
    public func clearUnpinned() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let unpinned = try queryItems().filter { !$0.isPinned }
        guard !unpinned.isEmpty else { return 0 }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM history WHERE is_pinned = 0;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try removeAssetsIfUnreferenced(unpinned.flatMap(assetPaths(for:)))
        return unpinned.count
    }

    @discardableResult
    public func cleanup(to limit: Int) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let boundedLimit = max(1, limit)
        let items = try queryItems()
        let unpinned = items.filter { !$0.isPinned }
        let pinnedCount = items.count - unpinned.count
        let allowedUnpinned = max(0, boundedLimit - pinnedCount)
        let expired = Array(unpinned.dropFirst(allowedUnpinned))
        guard !expired.isEmpty else { return 0 }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("DELETE FROM history WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            for item in expired {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(item.id, at: 1, to: statement)
                try stepDone(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try removeAssetsIfUnreferenced(expired.flatMap(assetPaths(for:)))
        return expired.count
    }

    public func count() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM history;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func storageUsageBytes() -> Int64 {
        let databaseFiles = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        let databaseBytes = databaseFiles.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            total += Int64(size ?? 0)
        }
        return assetStore.storageUsageBytes() + databaseBytes
    }

    private func removeAssetsIfUnreferenced(_ paths: [String]) throws {
        let candidates = Set(paths)
        guard !candidates.isEmpty else { return }
        let referenced = try queryItems().reduce(into: Set<String>()) { paths, item in
            paths.formUnion(assetPaths(for: item))
        }
        try assetStore.remove(Array(candidates.subtracting(referenced)))
    }

    private func recoverOrphanedAssets() throws {
        let referenced = try queryItems().reduce(into: Set<String>()) { paths, item in
            paths.formUnion(assetPaths(for: item))
        }
        try assetStore.removeOrphans(keeping: referenced)
    }

    private func migrateSchema() throws {
        var version = try readSchemaVersion()
        let latestVersion = Self.migrations.last?.version ?? 0
        guard version >= 0, version <= latestVersion else {
            throw ClipboardStoreError.database(
                "Database schema version \(version) is not supported by this ClipVault version."
            )
        }

        for migration in Self.migrations where migration.version > version {
            guard migration.version == version + 1 else {
                throw ClipboardStoreError.database("Database schema migrations are not sequential.")
            }
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute(migration.sql)
                try execute("PRAGMA user_version = \(migration.version);")
                try execute("COMMIT;")
                version = migration.version
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func readSchemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func queryItems() throws -> [ClipboardItem] {
        let statement = try prepare("""
            SELECT id, content_hash, kind, display_text, source_bundle_id,
                   source_application_name, created_at, is_pinned, is_screenshot,
                   representations_json, asset_paths_json, preview_asset_path
            FROM history ORDER BY created_at DESC, id DESC;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [ClipboardItem] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError }
            guard let id = text(statement, 0),
                  let contentHash = text(statement, 1),
                  let kindValue = text(statement, 2),
                  let kind = ClipboardContentKind(rawValue: kindValue),
                  let createdAtValue = optionalDouble(statement, 6),
                  let representationsJSON = text(statement, 9),
                  let assetPathsJSON = text(statement, 10) else { continue }
            let representations: [String: String] = try decode(representationsJSON)
            let assetPaths: [String: String] = try decode(assetPathsJSON)
            result.append(ClipboardItem(
                id: id,
                contentHash: contentHash,
                kind: kind,
                displayText: text(statement, 3),
                source: ClipboardSource(
                    bundleIdentifier: text(statement, 4),
                    applicationName: text(statement, 5)
                ),
                createdAt: Date(timeIntervalSince1970: createdAtValue),
                isPinned: sqlite3_column_int(statement, 7) != 0,
                isScreenshot: sqlite3_column_int(statement, 8) != 0,
                representations: representations,
                assetPaths: assetPaths,
                previewAssetPath: text(statement, 11)
            ))
        }
        return result
    }

    private func rowExists(contentHash: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM history WHERE content_hash = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(contentHash, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw databaseError
    }

    private func assetPaths(for item: ClipboardItem) -> [String] {
        Array(item.assetPaths.values) + (item.previewAssetPath.map { [$0] } ?? [])
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        do {
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        } catch {
            throw ClipboardStoreError.encoding(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ value: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(value.utf8))
        } catch {
            throw ClipboardStoreError.encoding(error.localizedDescription)
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let details = message.map { String(cString: $0) } ?? databaseMessage
            sqlite3_free(message)
            throw ClipboardStoreError.database(details)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw databaseError }
            return
        }
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        guard status == SQLITE_OK else { throw databaseError }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw databaseError }
    }

    private func bind(_ value: Int, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else { throw databaseError }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    private func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    private var databaseMessage: String {
        database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "Unknown SQLite error"
    }

    private var databaseError: ClipboardStoreError {
        .database(databaseMessage)
    }
}
