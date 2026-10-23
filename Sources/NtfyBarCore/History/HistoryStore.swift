import Foundation
import SQLite3

public enum InsertResult: Equatable, Sendable {
    case inserted, duplicate, failed
}

public enum HistoryError: Error, Equatable {
    case open(String)
    case sql(String)
}

/// Message history in SQLite (WAL, file mode 600). Plaintext on purpose — documented in the README.
/// The primary key (topic_id, id) is also the dedupe: `insert` returns false for a message we
/// already have, which is how replays after a reconnect are recognised.
@MainActor
public final class HistoryStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil
            throw HistoryError.open(msg)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS messages (
              topic_id TEXT NOT NULL, id TEXT NOT NULL, time INTEGER NOT NULL, received_at REAL NOT NULL,
              priority INTEGER NOT NULL, title TEXT, message TEXT, json TEXT NOT NULL,
              catch_up INTEGER NOT NULL DEFAULT 0, read INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (topic_id, id))
            """)
        try exec("CREATE INDEX IF NOT EXISTS messages_topic_time ON messages(topic_id, time)")
    }

    deinit { sqlite3_close(db) }

    // MARK: writes

    /// `.duplicate` when (topicId, id) is already stored; `.failed` on a database error.
    @discardableResult
    public func insert(_ m: Message) -> InsertResult {
        let sql = """
            INSERT OR IGNORE INTO messages (topic_id, id, time, received_at, priority, title, message, json, catch_up, read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let ok = run(sql, [.text(m.topicId.uuidString), .text(m.ntfy.id), .int(m.ntfy.time),
                           .real(m.receivedAt.timeIntervalSince1970), .int(Int64(m.priority)), .textOrNull(m.title),
                           .text(m.body), .text(m.raw), .int(m.isCatchUp ? 1 : 0), .int(m.read ? 1 : 0)])
        guard ok else { return .failed }
        return sqlite3_changes(db) == 1 ? .inserted : .duplicate
    }

    /// Closes the database; every later call fails cleanly (tests use this to simulate a broken store).
    public func close() {
        sqlite3_close(db)
        db = nil
    }

    /// topicId nil = every topic; id nil = every message of the topic(s).
    public func markRead(topicId: UUID? = nil, id: String? = nil) {
        var sql = "UPDATE messages SET read = 1 WHERE read = 0"
        var args: [SQLValue] = []
        if let topicId { sql += " AND topic_id = ?"; args.append(.text(topicId.uuidString)) }
        if let id { sql += " AND id = ?"; args.append(.text(id)) }
        run(sql, args)
    }

    /// Keeps the newest `keep` messages of the topic and drops anything older than `days`.
    public func purge(topicId: UUID, keep: Int, days: Int, now: Date = Date()) {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86_400
        run("""
            DELETE FROM messages WHERE topic_id = ?1 AND (time < ?2 OR rowid NOT IN (
              SELECT rowid FROM messages WHERE topic_id = ?1 ORDER BY time DESC, rowid DESC LIMIT ?3))
            """, [.text(topicId.uuidString), .int(cutoff), .int(Int64(max(keep, 0)))])
    }

    /// topicId nil = everything.
    public func clear(topicId: UUID? = nil) {
        if let topicId {
            run("DELETE FROM messages WHERE topic_id = ?", [.text(topicId.uuidString)])
        } else {
            run("DELETE FROM messages", [])
        }
    }

    // MARK: reads (newest first)

    public func recent(topicId: UUID? = nil, limit: Int) -> [Message] {
        if let topicId {
            return query("SELECT \(Self.columns) FROM messages WHERE topic_id = ? ORDER BY time DESC, rowid DESC LIMIT ?",
                         [.text(topicId.uuidString), .int(Int64(limit))])
        }
        return query("SELECT \(Self.columns) FROM messages ORDER BY received_at DESC, rowid DESC LIMIT ?", [.int(Int64(limit))])
    }

    public func message(topicId: UUID, id: String) -> Message? {
        query("SELECT \(Self.columns) FROM messages WHERE topic_id = ? AND id = ?", [.text(topicId.uuidString), .text(id)]).first
    }

    /// Messages strictly older than `before` (unix seconds).
    public func older(topicId: UUID, before: Int64, limit: Int) -> [Message] {
        query("SELECT \(Self.columns) FROM messages WHERE topic_id = ? AND time < ? ORDER BY time DESC, rowid DESC LIMIT ?",
              [.text(topicId.uuidString), .int(before), .int(Int64(limit))])
    }

    /// Messages strictly newer than `after` (unix seconds), still newest first.
    public func newer(topicId: UUID, after: Int64, limit: Int) -> [Message] {
        query("""
            SELECT * FROM (SELECT \(Self.columns), time AS t, rowid AS r FROM messages WHERE topic_id = ? AND time > ?
            ORDER BY time ASC, rowid ASC LIMIT ?) ORDER BY t DESC, r DESC
            """, [.text(topicId.uuidString), .int(after), .int(Int64(limit))])
    }

    /// Case-insensitive substring match on title and body.
    public func search(_ text: String, topicId: UUID? = nil, limit: Int) -> [Message] {
        let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        var sql = "SELECT \(Self.columns) FROM messages WHERE (title LIKE ?1 ESCAPE '\\' OR message LIKE ?1 ESCAPE '\\')"
        var args: [SQLValue] = [.text(pattern)]
        if let topicId { sql += " AND topic_id = ?2"; args.append(.text(topicId.uuidString)) }
        sql += " ORDER BY time DESC, rowid DESC LIMIT \(max(0, limit))"
        return query(sql, args)
    }

    public func unreadCount(topicId: UUID? = nil) -> Int {
        var sql = "SELECT COUNT(*) FROM messages WHERE read = 0"
        var args: [SQLValue] = []
        if let topicId { sql += " AND topic_id = ?"; args.append(.text(topicId.uuidString)) }
        var count = 0
        each(sql, args) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    public func count(topicId: UUID? = nil) -> Int {
        var count = 0
        if let topicId {
            each("SELECT COUNT(*) FROM messages WHERE topic_id = ?", [.text(topicId.uuidString)]) { count = Int(sqlite3_column_int64($0, 0)) }
        } else {
            each("SELECT COUNT(*) FROM messages", []) { count = Int(sqlite3_column_int64($0, 0)) }
        }
        return count
    }

    // MARK: SQLite plumbing

    enum SQLValue {
        case text(String), textOrNull(String?), int(Int64), real(Double)
    }

    private static let columns = "topic_id, json, received_at, catch_up, read"

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    @discardableResult
    private func run(_ sql: String, _ args: [SQLValue]) -> Bool {
        var ok = false
        each(sql, args, row: { _ in }, done: { ok = $0 })
        return ok
    }

    private func query(_ sql: String, _ args: [SQLValue]) -> [Message] {
        var out: [Message] = []
        each(sql, args) { stmt in
            guard let topicText = sqlite3_column_text(stmt, 0), let topicId = UUID(uuidString: String(cString: topicText)),
                  let jsonText = sqlite3_column_text(stmt, 1) else { return }
            let raw = String(cString: jsonText)
            guard let ntfy = try? JSONDecoder().decode(NtfyMessage.self, from: Data(raw.utf8)) else { return }
            out.append(Message(topicId: topicId, ntfy: ntfy,
                               receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                               isCatchUp: sqlite3_column_int(stmt, 3) != 0, read: sqlite3_column_int(stmt, 4) != 0,
                               raw: raw))
        }
        return out
    }

    private func each(_ sql: String, _ args: [SQLValue], row: (OpaquePointer) -> Void, done: (Bool) -> Void = { _ in }) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Log.history.error("prepare failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            done(false)
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let .text(s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case let .textOrNull(s):
                if let s { sqlite3_bind_text(stmt, idx, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, idx) }
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .real(v): sqlite3_bind_double(stmt, idx, v)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc != SQLITE_DONE { Log.history.error("step failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)") }
            done(rc == SQLITE_DONE)
            return
        }
    }
}
