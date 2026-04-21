import Foundation
import SQLite3
import ScanCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteScanStore: @unchecked Sendable, ScanStoreProtocol {
    private let db: OpaquePointer
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteError(message: "Unable to open SQLite database.")
        }
        self.db = handle

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS scan_runs (
                run_id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                payload TEXT NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS cache_entries (
                cache_key TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ignore_rules (
                rule_id TEXT PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                scope TEXT NOT NULL,
                created_at REAL NOT NULL,
                payload TEXT NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS review_dismiss_rules (
                rule_id TEXT PRIMARY KEY,
                signature TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                media_kind TEXT,
                created_at REAL NOT NULL,
                payload TEXT NOT NULL
            );
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    public func saveRun(_ run: ScanRun) throws {
        try lock.withLock {
            let payload = try encode(run)
            let sql = """
                INSERT INTO scan_runs(run_id, created_at, payload)
                VALUES(?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    created_at = excluded.created_at,
                    payload = excluded.payload;
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bindText(run.id, to: 1, statement: statement)
            sqlite3_bind_double(statement, 2, run.createdAt.timeIntervalSince1970)
            bindText(payload, to: 3, statement: statement)
            try step(statement)
        }
    }

    public func updateProgress(_ progress: ScanProgress, for runID: String) throws {
        try lock.withLock {
            guard var run = try loadRunUnlocked(id: runID) else {
                return
            }
            run.progress = progress
            try saveRunUnlocked(run)
        }
    }

    public func loadRun(id: String) throws -> ScanRun? {
        try lock.withLock {
            try loadRunUnlocked(id: id)
        }
    }

    public func latestRun() throws -> ScanRun? {
        try lock.withLock {
            let statement = try prepare("SELECT payload FROM scan_runs ORDER BY created_at DESC LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try decode(ScanRun.self, from: columnText(at: 0, statement: statement))
        }
    }

    public func latestCompletedRun() throws -> ScanRun? {
        try lock.withLock {
            let statement = try prepare("SELECT payload FROM scan_runs ORDER BY created_at DESC;")
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                let run = try decode(ScanRun.self, from: columnText(at: 0, statement: statement))
                if run.results != nil {
                    return run
                }
            }

            return nil
        }
    }

    public func cacheEntry(for key: String) throws -> CacheEntry? {
        try lock.withLock {
            let statement = try prepare("SELECT payload FROM cache_entries WHERE cache_key = ? LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            bindText(key, to: 1, statement: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try decode(CacheEntry.self, from: columnText(at: 0, statement: statement))
        }
    }

    public func upsertCacheEntry(_ entry: CacheEntry) throws {
        try lock.withLock {
            let payload = try encode(entry)
            let statement = try prepare("""
                INSERT INTO cache_entries(cache_key, payload)
                VALUES(?, ?)
                ON CONFLICT(cache_key) DO UPDATE SET payload = excluded.payload;
                """)
            defer { sqlite3_finalize(statement) }
            bindText(entry.key, to: 1, statement: statement)
            bindText(payload, to: 2, statement: statement)
            try step(statement)
        }
    }

    public func addIgnoreRule(_ rule: IgnoreRule) throws {
        try lock.withLock {
            let payload = try encode(rule)
            let statement = try prepare("""
                INSERT INTO ignore_rules(rule_id, path, scope, created_at, payload)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    scope = excluded.scope,
                    created_at = excluded.created_at,
                    payload = excluded.payload;
                """)
            defer { sqlite3_finalize(statement) }
            bindText(rule.id, to: 1, statement: statement)
            bindText(rule.path, to: 2, statement: statement)
            bindText(rule.scope.rawValue, to: 3, statement: statement)
            sqlite3_bind_double(statement, 4, rule.createdAt.timeIntervalSince1970)
            bindText(payload, to: 5, statement: statement)
            try step(statement)
        }
    }

    public func removeIgnoreRule(path: String) throws {
        try lock.withLock {
            let statement = try prepare("DELETE FROM ignore_rules WHERE path = ?;")
            defer { sqlite3_finalize(statement) }
            bindText(path, to: 1, statement: statement)
            try step(statement)
        }
    }

    public func listIgnoreRules() throws -> [IgnoreRule] {
        try lock.withLock {
            let statement = try prepare("SELECT payload FROM ignore_rules ORDER BY path ASC;")
            defer { sqlite3_finalize(statement) }

            var rules: [IgnoreRule] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rules.append(try decode(IgnoreRule.self, from: columnText(at: 0, statement: statement)))
            }
            return rules
        }
    }

    public func addReviewDismissRule(_ rule: ReviewDismissRule) throws {
        try lock.withLock {
            let payload = try encode(rule)
            let statement = try prepare("""
                INSERT INTO review_dismiss_rules(rule_id, signature, kind, media_kind, created_at, payload)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(signature) DO UPDATE SET
                    kind = excluded.kind,
                    media_kind = excluded.media_kind,
                    created_at = excluded.created_at,
                    payload = excluded.payload;
                """)
            defer { sqlite3_finalize(statement) }
            bindText(rule.id, to: 1, statement: statement)
            bindText(rule.signature, to: 2, statement: statement)
            bindText(rule.kind.rawValue, to: 3, statement: statement)
            if let mediaKind = rule.mediaKind?.rawValue {
                bindText(mediaKind, to: 4, statement: statement)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, rule.createdAt.timeIntervalSince1970)
            bindText(payload, to: 6, statement: statement)
            try step(statement)
        }
    }

    public func listReviewDismissRules() throws -> [ReviewDismissRule] {
        try lock.withLock {
            let statement = try prepare("SELECT payload FROM review_dismiss_rules ORDER BY created_at DESC;")
            defer { sqlite3_finalize(statement) }

            var rules: [ReviewDismissRule] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rules.append(try decode(ReviewDismissRule.self, from: columnText(at: 0, statement: statement)))
            }
            return rules
        }
    }

    private func loadRunUnlocked(id: String) throws -> ScanRun? {
        let statement = try prepare("SELECT payload FROM scan_runs WHERE run_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bindText(id, to: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decode(ScanRun.self, from: columnText(at: 0, statement: statement))
    }

    private func saveRunUnlocked(_ run: ScanRun) throws {
        let payload = try encode(run)
        let statement = try prepare("""
            INSERT INTO scan_runs(run_id, created_at, payload)
            VALUES(?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                created_at = excluded.created_at,
                payload = excluded.payload;
            """)
        defer { sqlite3_finalize(statement) }
        bindText(run.id, to: 1, statement: statement)
        sqlite3_bind_double(statement, 2, run.createdAt.timeIntervalSince1970)
        bindText(payload, to: 3, statement: statement)
        try step(statement)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SQLiteError(message: "Failed to encode JSON payload.")
        }
        return string
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw SQLiteError(message: "Failed to decode SQLite text payload.")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func execute(_ sql: String) throws {
        try lock.withLock {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError(message: currentErrorMessage())
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(message: currentErrorMessage())
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(message: currentErrorMessage())
        }
    }

    private func bindText(_ value: String, to index: Int32, statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(at index: Int32, statement: OpaquePointer) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: pointer)
    }

    private func currentErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

private struct SQLiteError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) throws -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
