import Foundation
import SQLite3

/// One face found in a library photo, as saved in the on-device index. No pixels: just a vector and where the face was.
struct IndexedFace: Sendable, Equatable {
    var assetId: String
    var takenAt: Date?
    var embedding: FaceEmbedding
    /// Face box and image size in pixels, at the size the photo was scanned.
    var box: CGRect
    var imageSize: CGSize

    var areaFraction: Float {
        let total = imageSize.width * imageSize.height
        return total > 0 ? Float(box.width * box.height / total) : 0
    }
}

/// The persistent face index: every face found in the camera roll, saved on this phone so a rescan is never needed and
/// results survive relaunch. Embeddings never leave the device (hard privacy rule), so this file is never uploaded:
/// it lives in Application Support, is excluded from backups, and is erased on sign-out.
///
/// SQLite because the index can reach tens of thousands of faces (about 2 KB each) and has to resume cleanly if the
/// app is killed mid-scan: every photo is written in its own transaction, and "scanned" is simply "has a row".
actor FaceIndexStore {
    /// Bumped when embeddings stop being comparable (same rule as `FaceEnrollmentStore`'s key prefix). An index built by
    /// another version is wiped on open and rebuilt by the backfill.
    static let embeddingVersion = "v3"

    // Touched only inside the actor, plus deinit (no other reference exists by then).
    private nonisolated(unsafe) var db: OpaquePointer?
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FaceIndex", isDirectory: true).appendingPathComponent("index.sqlite")
    }

    init(url: URL = FaceIndexStore.defaultURL) {
        self.url = url
        Self.prepareDirectory(for: url)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        db = handle
        Self.exec(handle, "PRAGMA journal_mode=WAL")
        Self.exec(handle, """
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, taken_at REAL, scanned_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS faces(
                id INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                aligned INTEGER NOT NULL, bx REAL, by REAL, bw REAL, bh REAL, iw REAL, ih REAL, vector BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS faces_asset ON faces(asset_id);
            CREATE TABLE IF NOT EXISTS sent(asset_id TEXT NOT NULL, friend_id TEXT NOT NULL, PRIMARY KEY(asset_id, friend_id));
            PRAGMA foreign_keys=ON;
            """)
        Self.exec(handle, "PRAGMA foreign_keys=ON")
        if Self.meta(handle, "embedding_version") != Self.embeddingVersion {
            Self.exec(handle, "DELETE FROM faces; DELETE FROM assets;")
            Self.setMeta(handle, "embedding_version", Self.embeddingVersion)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writing

    /// Records that `assetId` has been scanned and what was found in it (possibly nothing). Replaces an earlier scan.
    func record(assetId: String, takenAt: Date?, faces: [IndexedFace], now: Date = Date()) {
        guard let db else { return }
        Self.exec(db, "BEGIN")
        Self.run(db, "DELETE FROM assets WHERE id = ?", [.text(assetId)])
        Self.run(db, "INSERT INTO assets(id, taken_at, scanned_at) VALUES(?,?,?)",
                 [.text(assetId), takenAt.map { .real($0.timeIntervalSince1970) } ?? .null, .real(now.timeIntervalSince1970)])
        for f in faces {
            Self.run(db, "INSERT INTO faces(asset_id, aligned, bx, by, bw, bh, iw, ih, vector) VALUES(?,?,?,?,?,?,?,?,?)", [
                .text(assetId), .int(f.embedding.aligned ? 1 : 0),
                .real(f.box.minX), .real(f.box.minY), .real(f.box.width), .real(f.box.height),
                .real(f.imageSize.width), .real(f.imageSize.height),
                .blob(f.embedding.vector.withUnsafeBufferPointer { Data(buffer: $0) }),
            ])
        }
        Self.exec(db, "COMMIT")
    }

    /// Forgets photos that are no longer in the library (deleted, or outside a limited-access selection).
    func remove(assetIds: [String]) {
        guard let db, !assetIds.isEmpty else { return }
        Self.exec(db, "BEGIN")
        for id in assetIds { Self.run(db, "DELETE FROM assets WHERE id = ?", [.text(id)]) }
        Self.exec(db, "COMMIT")
    }

    func erase() {
        guard let db else { return }
        Self.exec(db, "DELETE FROM faces; DELETE FROM assets; DELETE FROM sent; DELETE FROM meta WHERE key != 'embedding_version';")
        Self.exec(db, "VACUUM")
    }

    // MARK: - Reading

    func indexedAssetIds() -> Set<String> {
        Set(Self.column(db, "SELECT id FROM assets"))
    }

    var assetCount: Int { Int(Self.scalar(db, "SELECT COUNT(*) FROM assets") ?? 0) }
    var faceCount: Int { Int(Self.scalar(db, "SELECT COUNT(*) FROM faces") ?? 0) }

    func faces(for assetId: String) -> [IndexedFace]? {
        guard let db, Self.scalar(db, "SELECT COUNT(*) FROM assets WHERE id = ?", [.text(assetId)]) == 1 else { return nil }
        return queryFaces("SELECT f.asset_id, a.taken_at, f.aligned, f.bx, f.by, f.bw, f.bh, f.iw, f.ih, f.vector FROM faces f JOIN assets a ON a.id = f.asset_id WHERE f.asset_id = ?", [.text(assetId)])
    }

    /// Faces grouped by photo, newest photo first. Loads the whole index: roughly 2 KB per face.
    func facesByAsset() -> [(assetId: String, takenAt: Date?, faces: [IndexedFace])] {
        let all = queryFaces("SELECT f.asset_id, a.taken_at, f.aligned, f.bx, f.by, f.bw, f.bh, f.iw, f.ih, f.vector FROM faces f JOIN assets a ON a.id = f.asset_id ORDER BY a.taken_at DESC, f.asset_id", [])
        var out: [(assetId: String, takenAt: Date?, faces: [IndexedFace])] = []
        for f in all {
            if out.last?.assetId == f.assetId { out[out.count - 1].faces.append(f) } else { out.append((f.assetId, f.takenAt, [f])) }
        }
        return out
    }

    // MARK: - Sent ledger: photos already handed to a friend, so a re-offer never repeats them.

    func markSent(assetIds: [String], to friendId: UUID) {
        guard let db, !assetIds.isEmpty else { return }
        Self.exec(db, "BEGIN")
        for id in assetIds { Self.run(db, "INSERT OR IGNORE INTO sent(asset_id, friend_id) VALUES(?,?)", [.text(id), .text(friendId.uuidString)]) }
        Self.exec(db, "COMMIT")
    }

    func sentAssetIds(to friendId: UUID) -> Set<String> {
        Set(Self.column(db, "SELECT asset_id FROM sent WHERE friend_id = ?", [.text(friendId.uuidString)]))
    }

    // MARK: - SQLite plumbing

    private enum Value { case text(String), int(Int64), real(Double), blob(Data), null }

    private func queryFaces(_ sql: String, _ args: [Value]) -> [IndexedFace] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, args)
        var out: [IndexedFace] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let taken: Date? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let bytes = sqlite3_column_blob(stmt, 9), count = Int(sqlite3_column_bytes(stmt, 9))
            let vector = bytes.map { raw in
                Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: count / MemoryLayout<Float>.size))
            } ?? []
            out.append(IndexedFace(
                assetId: String(cString: sqlite3_column_text(stmt, 0)), takenAt: taken,
                embedding: FaceEmbedding(vector: vector, aligned: sqlite3_column_int(stmt, 2) == 1),
                box: CGRect(x: sqlite3_column_double(stmt, 3), y: sqlite3_column_double(stmt, 4),
                            width: sqlite3_column_double(stmt, 5), height: sqlite3_column_double(stmt, 6)),
                imageSize: CGSize(width: sqlite3_column_double(stmt, 7), height: sqlite3_column_double(stmt, 8))))
        }
        return out
    }

    private nonisolated static func prepareDirectory(for url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            // Readable once the phone has been unlocked after boot, so the background scan can run while it is locked.
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
    }

    @discardableResult
    private nonisolated static func exec(_ db: OpaquePointer?, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private nonisolated static func bind(_ stmt: OpaquePointer?, _ args: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), transient) }
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
    }

    private nonisolated static func run(_ db: OpaquePointer?, _ sql: String, _ args: [Value]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        sqlite3_step(stmt)
    }

    private nonisolated static func scalar(_ db: OpaquePointer?, _ sql: String, _ args: [Value] = []) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private nonisolated static func column(_ db: OpaquePointer?, _ sql: String, _ args: [Value] = []) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    private nonisolated static func meta(_ db: OpaquePointer?, _ key: String) -> String? {
        column(db, "SELECT value FROM meta WHERE key = ?", [.text(key)]).first
    }

    private nonisolated static func setMeta(_ db: OpaquePointer?, _ key: String, _ value: String) {
        run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [.text(key), .text(value)])
    }
}
