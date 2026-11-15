import Foundation
import SQLite3
import CryptoKit

public enum StoreError: Error { case open(String), sql(String) }

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum Bind {
    case int(Int64), double(Double), text(String), blob(Data), null
}

/// SQLite-backed clipboard history. All access is serialised by a lock; operations are short.
public final class HistoryStore: @unchecked Sendable {
    public static let previewLimit = 4000

    public let directory: URL
    public let imagesDirectory: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(directory: URL) throws {
        self.directory = directory
        self.imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let dbURL = directory.appendingPathComponent("history.sqlite")
        do {
            try openDatabase(at: dbURL)
        } catch {
            // Never destroy a database we can't read: move it aside and start fresh.
            sqlite3_close(db); db = nil
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: dbURL.path + suffix)
                let dst = URL(fileURLWithPath: dbURL.path + ".corrupt-\(stamp)" + suffix)
                try? fm.moveItem(at: src, to: dst)
            }
            try openDatabase(at: dbURL)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
    }

    deinit { sqlite3_close(db) }

    private func openDatabase(at url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA secure_delete = ON")
        try exec("""
        CREATE TABLE IF NOT EXISTS entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            text TEXT,
            rtf BLOB,
            html BLOB,
            image_file TEXT,
            image_w INTEGER NOT NULL DEFAULT 0,
            image_h INTEGER NOT NULL DEFAULT 0,
            byte_size INTEGER NOT NULL DEFAULT 0,
            hash TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL,
            last_copied_at REAL NOT NULL,
            copy_count INTEGER NOT NULL DEFAULT 1,
            source_app TEXT,
            source_bundle TEXT,
            pinned INTEGER NOT NULL DEFAULT 0,
            favorite INTEGER NOT NULL DEFAULT 0,
            tags TEXT NOT NULL DEFAULT '',
            ocr TEXT
        )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_entries_recent ON entries(last_copied_at)")
        // Integrity probe so a damaged file is detected at open time.
        _ = try query("SELECT count(*) FROM entries LIMIT 1", []) { _ in 0 }
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    @discardableResult
    private func run(_ sql: String, _ binds: [Bind] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    private func query<T>(_ sql: String, _ binds: [Bind], _ row: (OpaquePointer) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s, binds)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { out.append(row(s)) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                v.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writing

    /// Stores a clip, or bumps the existing entry when identical content was already saved.
    @discardableResult
    public func save(_ clip: NewClip, now: Date = Date()) throws -> (id: Int64, isNew: Bool) {
        lock.lock(); defer { lock.unlock() }
        let digest: String
        var byteSize = 0
        if clip.kind == .image, let png = clip.imagePNG {
            digest = "img:" + Self.hash(png); byteSize = png.count
        } else {
            let t = clip.text ?? ""
            digest = "txt:" + Self.hash(Data(t.utf8)); byteSize = t.utf8.count
        }

        let existing = try query("SELECT id FROM entries WHERE hash = ?", [.text(digest)]) { sqlite3_column_int64($0, 0) }
        if let id = existing.first {
            try run("""
            UPDATE entries SET last_copied_at = ?, copy_count = copy_count + 1,
              source_app = COALESCE(?, source_app), source_bundle = COALESCE(?, source_bundle),
              rtf = COALESCE(rtf, ?), html = COALESCE(html, ?)
            WHERE id = ?
            """, [.double(now.timeIntervalSince1970),
                  clip.sourceApp.map { .text($0) } ?? .null,
                  clip.sourceBundleID.map { .text($0) } ?? .null,
                  clip.rtf.map { .blob($0) } ?? .null,
                  clip.html.map { .blob($0) } ?? .null,
                  .int(id)])
            return (id, false)
        }

        var imageFile: String?
        if clip.kind == .image, let png = clip.imagePNG {
            let name = String(digest.dropFirst(4)) + ".png"
            let url = imagesDirectory.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            imageFile = name
        }

        try run("""
        INSERT INTO entries(kind, text, rtf, html, image_file, image_w, image_h, byte_size, hash,
                            created_at, last_copied_at, source_app, source_bundle)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(clip.kind.rawValue),
              clip.text.map { .text($0) } ?? .null,
              clip.rtf.map { .blob($0) } ?? .null,
              clip.html.map { .blob($0) } ?? .null,
              imageFile.map { .text($0) } ?? .null,
              .int(Int64(clip.imageWidth)), .int(Int64(clip.imageHeight)), .int(Int64(byteSize)),
              .text(digest), .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
              clip.sourceApp.map { .text($0) } ?? .null,
              clip.sourceBundleID.map { .text($0) } ?? .null])
        return (sqlite3_last_insert_rowid(db), true)
    }

    public func touch(_ id: Int64, now: Date = Date()) {
        _ = try? run("UPDATE entries SET last_copied_at = ?, copy_count = copy_count + 1 WHERE id = ?",
                     [.double(now.timeIntervalSince1970), .int(id)])
    }

    public func setPinned(_ id: Int64, _ value: Bool) { _ = try? run("UPDATE entries SET pinned = ? WHERE id = ?", [.int(value ? 1 : 0), .int(id)]) }
    public func setFavorite(_ id: Int64, _ value: Bool) { _ = try? run("UPDATE entries SET favorite = ? WHERE id = ?", [.int(value ? 1 : 0), .int(id)]) }
    public func setOCR(_ id: Int64, _ text: String) { _ = try? run("UPDATE entries SET ocr = ? WHERE id = ?", [.text(text), .int(id)]) }

    public func setTags(_ id: Int64, _ tags: [String]) {
        let clean = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: " ") }
            .filter { !$0.isEmpty }
        _ = try? run("UPDATE entries SET tags = ? WHERE id = ?", [.text(clean.joined(separator: ",")), .int(id)])
    }

    public func delete(ids: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            let files = (try? query("SELECT image_file FROM entries WHERE id = ?", [.int(id)]) { Self.str($0, 0) }) ?? []
            if (try? run("DELETE FROM entries WHERE id = ?", [.int(id)])) != nil {
                for case let f? in files { try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(f)) }
            }
        }
    }

    /// Removes history. Pinned entries survive when `keepPinned` is true.
    public func clear(keepPinned: Bool) {
        lock.lock(); defer { lock.unlock() }
        let files = (try? query("SELECT image_file FROM entries WHERE image_file IS NOT NULL" + (keepPinned ? " AND pinned = 0" : ""), []) { Self.str($0, 0) }) ?? []
        _ = try? run("DELETE FROM entries" + (keepPinned ? " WHERE pinned = 0" : ""))
        for case let f? in files { try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(f)) }
        _ = try? exec("VACUUM")
    }

    /// Applies retention. Pinned entries are never removed. Returns the number of removed entries.
    @discardableResult
    public func purge(olderThanDays days: Int, maxEntries: Int, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        var ids = Set<Int64>()
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let old = (try? query("SELECT id FROM entries WHERE pinned = 0 AND last_copied_at < ?", [.double(cutoff)]) { sqlite3_column_int64($0, 0) }) ?? []
            ids.formUnion(old)
        }
        if maxEntries > 0 {
            let extra = (try? query("SELECT id FROM entries WHERE pinned = 0 ORDER BY last_copied_at DESC LIMIT -1 OFFSET ?", [.int(Int64(maxEntries))]) { sqlite3_column_int64($0, 0) }) ?? []
            ids.formUnion(extra)
        }
        delete(ids: Array(ids))
        return ids.count
    }

    // MARK: - Reading

    private static let columns = """
    id, kind, substr(text, 1, \(previewLimit)), length(text), image_file, image_w, image_h, byte_size,
    created_at, last_copied_at, copy_count, source_app, source_bundle, pinned, favorite, tags,
    substr(ocr, 1, \(previewLimit)), (rtf IS NOT NULL OR html IS NOT NULL)
    """

    private static func entry(_ s: OpaquePointer) -> ClipEntry {
        ClipEntry(
            id: sqlite3_column_int64(s, 0),
            kind: ContentKind(rawValue: str(s, 1) ?? "") ?? .text,
            text: str(s, 2) ?? "",
            textLength: Int(sqlite3_column_int64(s, 3)),
            imageFile: str(s, 4),
            imageWidth: Int(sqlite3_column_int64(s, 5)),
            imageHeight: Int(sqlite3_column_int64(s, 6)),
            byteSize: Int(sqlite3_column_int64(s, 7)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)),
            lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 9)),
            copyCount: Int(sqlite3_column_int64(s, 10)),
            sourceApp: str(s, 11),
            sourceBundleID: str(s, 12),
            pinned: sqlite3_column_int64(s, 13) != 0,
            favorite: sqlite3_column_int64(s, 14) != 0,
            tags: (str(s, 15) ?? "").split(separator: ",").map(String.init),
            ocrText: str(s, 16),
            hasRichText: sqlite3_column_int64(s, 17) != 0)
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private func whereClause(search: String, filter: HistoryFilter, now: Date) -> (String, [Bind]) {
        var clauses: [String] = []
        var binds: [Bind] = []
        if let f = filter.sql {
            clauses.append(f)
            if filter == .recent { binds.append(.double(now.addingTimeInterval(-86400).timeIntervalSince1970)) }
        }
        for term in search.split(whereSeparator: { $0.isWhitespace }) {
            let like = "%" + Self.escapeLike(String(term)) + "%"
            clauses.append("(text LIKE ?1 ESCAPE '\\' OR ocr LIKE ?1 ESCAPE '\\' OR source_app LIKE ?1 ESCAPE '\\' OR tags LIKE ?1 ESCAPE '\\' OR kind LIKE ?1 ESCAPE '\\')".replacingOccurrences(of: "?1", with: "?"))
            binds.append(contentsOf: Array(repeating: .text(like), count: 5))
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), binds)
    }

    public func fetch(search: String = "", filter: HistoryFilter = .all, limit: Int = 100, offset: Int = 0, now: Date = Date()) -> [ClipEntry] {
        let (w, b) = whereClause(search: search, filter: filter, now: now)
        let sql = "SELECT \(Self.columns) FROM entries \(w) ORDER BY pinned DESC, last_copied_at DESC, id DESC LIMIT ? OFFSET ?"
        return (try? query(sql, b + [.int(Int64(limit)), .int(Int64(offset))], Self.entry)) ?? []
    }

    public func count(search: String = "", filter: HistoryFilter = .all, now: Date = Date()) -> Int {
        let (w, b) = whereClause(search: search, filter: filter, now: now)
        return (try? query("SELECT count(*) FROM entries \(w)", b) { Int(sqlite3_column_int64($0, 0)) })?.first ?? 0
    }

    public func entry(id: Int64) -> ClipEntry? {
        (try? query("SELECT \(Self.columns) FROM entries WHERE id = ?", [.int(id)], Self.entry))?.first
    }

    public func payload(id: Int64) -> ClipPayload? {
        let rows = try? query("SELECT kind, text, rtf, html, image_file FROM entries WHERE id = ?", [.int(id)]) { s -> ClipPayload in
            let kind = ContentKind(rawValue: Self.str(s, 0) ?? "") ?? .text
            let text = Self.str(s, 1)
            func blob(_ i: Int32) -> Data? {
                guard let p = sqlite3_column_blob(s, i) else { return nil }
                return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
            }
            return ClipPayload(kind: kind, text: text, rtf: blob(2), html: blob(3),
                               imageURL: Self.str(s, 4).map { self.imagesDirectory.appendingPathComponent($0) },
                               filePaths: kind == .file ? (text ?? "").components(separatedBy: "\n") : [])
        }
        return rows?.first
    }

    public func totalCount() -> Int { count() }
}
