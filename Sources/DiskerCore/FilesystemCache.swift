import Darwin
import Foundation
import GRDB

let cacheSchemaVersion: Int32 = 2
let emptyScanMetrics: ScanMetrics = ScanMetrics(entries: 0, directories: 0, bulkCalls: 0, metadataCalls: 0, contentBytesRead: 0)

func cacheParent(_ path: Data) -> Data? {
    if path == Data("/".utf8) { return nil }
    guard let slash: Data.Index = path.lastIndex(of: 47), slash > path.startIndex else { return Data("/".utf8) }
    return Data(path[..<slash])
}

func cacheRange(_ path: Data) -> (Data, Data) {
    let lower: Data = path.last == 47 ? path : path + Data([47])
    var upper: Data = lower
    upper[upper.count - 1] = 48
    return (lower, upper)
}

func cacheContains(_ path: Data, in directory: Data) -> Bool {
    path == directory || path.starts(with: cacheRange(directory).0)
}

func cacheDepth(_ path: Data) -> Int { path == Data("/".utf8) ? 0 : path.reduce(0) { $0 + ($1 == 47 ? 1 : 0) } }

func createFilesystemCache(_ db: Database) throws {
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS nodes (
            path BLOB PRIMARY KEY, parent BLOB, name BLOB NOT NULL, depth INTEGER NOT NULL,
            directory INTEGER NOT NULL, metadata BLOB NOT NULL, logical INTEGER NOT NULL,
            allocated INTEGER NOT NULL, total_logical INTEGER NOT NULL, total_allocated INTEGER NOT NULL,
            total_count INTEGER NOT NULL, seen INTEGER NOT NULL, modified_revision INTEGER NOT NULL,
            total_revision INTEGER NOT NULL, scan_revision INTEGER NOT NULL, scan_date REAL NOT NULL,
            scan_metrics BLOB, directory_count INTEGER NOT NULL, completed_count INTEGER NOT NULL,
            progress REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS node_children ON nodes(parent,total_allocated DESC,name);
        CREATE INDEX IF NOT EXISTS node_depth ON nodes(depth);
        CREATE INDEX IF NOT EXISTS node_git_markers ON nodes(name,path);
        CREATE INDEX IF NOT EXISTS node_directory_identity ON nodes(substr(metadata,9,16)) WHERE directory=1;
        CREATE TABLE IF NOT EXISTS physical_paths(path BLOB NOT NULL,physical BLOB NOT NULL,PRIMARY KEY(path,physical)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS physical_locations ON physical_paths(physical,path);
        CREATE TABLE IF NOT EXISTS directories (
            path BLOB PRIMARY KEY, done INTEGER NOT NULL, observed INTEGER NOT NULL DEFAULT 0, report BLOB
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS pending_directories ON directories(done,path);
        CREATE TABLE IF NOT EXISTS aliases (path BLOB PRIMARY KEY,target BLOB NOT NULL,seen INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS git_cache (
            path TEXT PRIMARY KEY,revision INTEGER NOT NULL,fingerprint BLOB NOT NULL,info BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS cache_state (
            id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,epoch INTEGER NOT NULL,checkpoint BLOB
        );
        INSERT OR IGNORE INTO cache_state(id,revision,epoch) VALUES(1,0,0);
        """)
}

func markCacheAncestors(_ db: Database, path: Data) throws {
    let insert: Statement = try db.makeStatement(sql: "INSERT OR IGNORE INTO dirty(path,depth) VALUES(?,?)")
    var current: Data? = path
    while let value: Data = current {
        try insert.execute(arguments: [value, cacheDepth(value)])
        current = cacheParent(value)
    }
}

func beginCacheChanges(_ db: Database) throws -> Int64 {
    try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS dirty(path BLOB PRIMARY KEY,depth INTEGER NOT NULL) WITHOUT ROWID; DELETE FROM dirty; UPDATE cache_state SET revision=revision+1 WHERE id=1")
    return try Int64.fetchOne(db, sql: "SELECT revision FROM cache_state WHERE id=1")!
}

func removeCacheTree(_ db: Database, path: Data, revision: Int64) throws {
    let (lower, upper): (Data, Data) = cacheRange(path)
    try db.execute(sql: "DELETE FROM nodes WHERE path=? OR (path>=? AND path<?)", arguments: [path, lower, upper])
    try db.execute(sql: "DELETE FROM directories WHERE path=? OR (path>=? AND path<?)", arguments: [path, lower, upper])
    try db.execute(sql: "DELETE FROM physical_paths WHERE path=? OR (path>=? AND path<?)", arguments: [path, lower, upper])
    let affected: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM aliases WHERE target=? OR (target>=? AND target<?)", arguments: [path, lower, upper])
    try db.execute(sql: "DELETE FROM aliases WHERE path=? OR (path>=? AND path<?) OR target=? OR (target>=? AND target<?)", arguments: [path, lower, upper, path, lower, upper])
    for alias: Data in affected {
        try db.execute(sql: "UPDATE directories SET done=0,report=NULL WHERE path=?", arguments: [alias])
        try markCacheAncestors(db, path: alias)
    }
    if let parent: Data = cacheParent(path) {
        try db.execute(sql: "UPDATE nodes SET modified_revision=?,scan_revision=? WHERE path=?", arguments: [revision, revision, parent])
        try markCacheAncestors(db, path: parent)
    }
}

func recordCacheEntries(_ db: Database, entries: [ScanEntry], directory: Data?, epoch: Int64, revision: Int64) throws {
    let upsert: Statement = try db.makeStatement(sql: """
        INSERT INTO nodes(path,parent,name,depth,directory,metadata,logical,allocated,total_logical,total_allocated,total_count,seen,modified_revision,total_revision,scan_revision,scan_date,directory_count,completed_count,progress)
        VALUES(?,?,?,?,?,?,?,?,?,?,1,?,?,?,?,?,?,0,0)
        ON CONFLICT(path) DO UPDATE SET parent=excluded.parent,name=excluded.name,depth=excluded.depth,
            directory=excluded.directory,metadata=excluded.metadata,logical=excluded.logical,allocated=excluded.allocated,
            seen=excluded.seen,scan_revision=excluded.scan_revision,scan_date=excluded.scan_date,
            total_logical=CASE WHEN excluded.directory=0 THEN excluded.logical ELSE nodes.total_logical END,
            total_allocated=CASE WHEN excluded.directory=0 THEN excluded.allocated ELSE nodes.total_allocated END,
            total_count=CASE WHEN excluded.directory=0 THEN 1 ELSE nodes.total_count END,
            directory_count=CASE WHEN excluded.directory=0 THEN 0 ELSE nodes.directory_count END,
            completed_count=CASE WHEN excluded.directory=0 THEN 0 ELSE nodes.completed_count END,
            progress=CASE WHEN excluded.directory=0 THEN 0 ELSE nodes.progress END,
            modified_revision=CASE WHEN substr(nodes.metadata,1,24)<>substr(excluded.metadata,1,24)
                OR (excluded.directory=0 AND substr(nodes.metadata,25,8)<>substr(excluded.metadata,25,8))
                OR substr(nodes.metadata,33,88)<>substr(excluded.metadata,33,88)
                OR substr(nodes.metadata,137)<>substr(excluded.metadata,137) THEN excluded.modified_revision ELSE nodes.modified_revision END,
            total_revision=CASE WHEN excluded.directory=0 AND (substr(nodes.metadata,1,120)<>substr(excluded.metadata,1,120)
                OR substr(nodes.metadata,137)<>substr(excluded.metadata,137)) THEN excluded.total_revision ELSE nodes.total_revision END
        """)
    let previous: Statement = try db.makeStatement(sql: "SELECT metadata,seen FROM nodes WHERE path=?")
    let date: Double = Date().timeIntervalSince1970
    var changed: Set<Data> = []
    for entry: ScanEntry in entries {
        let old: Row? = try Row.fetchOne(previous, arguments: [entry.path])
        let metadata: FileMetadata? = try old.map { try decodeMetadata($0["metadata"]) }
        let isDirectory: Bool = entry.metadata.kind == .directory
        if let metadata, metadata.kind == .directory,
           !isDirectory || metadata.device != entry.metadata.device || metadata.inode != entry.metadata.inode || metadata.birthTime != entry.metadata.birthTime {
            try removeCacheTree(db, path: entry.path, revision: revision)
        } else if let metadata, isDirectory,
                  metadata.modificationTime != entry.metadata.modificationTime || metadata.changeTime != entry.metadata.changeTime {
            try invalidateCacheListing(db, path: entry.path)
        }
        let logical: UInt64 = isDirectory ? 0 : entry.metadata.logicalBytes
        guard logical <= Int64.max, entry.metadata.allocatedBytes <= Int64.max else { throw IndexError.malformedCache("File size exceeds SQLite integer range") }
        let membership: Int64 = entry.path == directory ? (old?["seen"] as Int64? ?? 0) : epoch
        try upsert.execute(arguments: [entry.path, cacheParent(entry.path), entry.name, cacheDepth(entry.path), isDirectory,
            encodeMetadata(entry.metadata), Int64(logical), Int64(entry.metadata.allocatedBytes), Int64(logical),
            Int64(entry.metadata.allocatedBytes), membership, revision, revision, revision, date, isDirectory ? 1 : 0])
        if isDirectory {
            try db.execute(sql: "INSERT OR IGNORE INTO directories(path,done) VALUES(?,0)", arguments: [entry.path])
            changed.insert(entry.path)
        }
        if let parent: Data = cacheParent(entry.path) { changed.insert(parent) }
    }
    for path: Data in changed { try markCacheAncestors(db, path: path) }
}

func rebuildCacheTotals(_ db: Database) throws {
    let paths: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM dirty ORDER BY depth DESC")
    let update: Statement = try db.makeStatement(sql: """
        WITH totals AS (
            SELECT COALESCE(SUM(total_logical),0) AS logical,COALESCE(SUM(total_allocated),0) AS allocated,
                COALESCE(SUM(total_count),0) AS count,COALESCE(MAX(total_revision),0) AS revision,
                COALESCE(MAX(scan_revision),0) AS scan_revision,COALESCE(MAX(scan_date),0) AS date,
                COALESCE(SUM(directory_count),0) AS directories,COALESCE(SUM(completed_count),0) AS completed,
                COALESCE(SUM(CASE WHEN directory=1 THEN progress ELSE 0 END),0) AS progress,
                COALESCE(SUM(directory),0) AS branches
            FROM nodes INDEXED BY node_children WHERE parent=?
        )
        UPDATE nodes SET
            (total_logical,total_allocated,total_count,total_revision,scan_revision,scan_date,directory_count,completed_count,progress)=
            (SELECT nodes.logical+t.logical,nodes.allocated+t.allocated,1+t.count,MAX(nodes.modified_revision,t.revision),
                MAX(nodes.scan_revision,t.scan_revision),MAX(nodes.scan_date,t.date),1+t.directories,COALESCE(d.done,0)+t.completed,
                (COALESCE(d.observed,0)+t.progress)/(1.0+t.branches)
             FROM totals t LEFT JOIN directories d ON d.path=nodes.path)
        WHERE path=? AND directory=1
        """)
    for path: Data in paths { try update.execute(arguments: [path, path]) }
}

func resolveCacheAlias(_ db: Database, path: Data) throws -> Data {
    var current: Data = path
    var visited: Set<Data> = []
    while visited.insert(current).inserted {
        var ancestor: Data? = current
        var replacement: Data?
        while let candidate: Data = ancestor {
            if let target: Data = try Data.fetchOne(db, sql: "SELECT target FROM aliases WHERE path=?", arguments: [candidate]) {
                replacement = target + current.dropFirst(candidate.count)
                break
            }
            ancestor = cacheParent(candidate)
        }
        guard let replacement else { return current }
        current = replacement
    }
    throw IndexError.malformedCache("Filesystem alias cycle")
}

func cacheNode(_ db: Database, path: Data) throws -> IndexedNode? {
    let query: String = "SELECT *, (SELECT target FROM aliases WHERE aliases.path=nodes.path) AS alias_target FROM nodes WHERE path=?"
    if let row: Row = try Row.fetchOne(db, sql: query, arguments: [path]) { return try decodeCacheNode(row) }
    let resolved: Data = try resolveCacheAlias(db, path: path)
    guard let row: Row = try Row.fetchOne(db, sql: query, arguments: [resolved]) else { return nil }
    return try decodeCacheNode(row)
}

func decodeCacheNode(_ row: Row) throws -> IndexedNode {
    try indexedNode(RowData(path: row["path"], parent: row["parent"], name: row["name"], metadata: row["metadata"], logical: row["total_logical"], allocated: row["total_allocated"], count: row["total_count"], aliasTarget: row["alias_target"]))
}

struct CacheProjection {
    let logical: UInt64
    let allocated: UInt64
    let count: Int64
    let revision: Int64
    let date: Double
    let complete: Bool
    let progress: Double
    let metrics: ScanMetrics
    let scopes: [Data]
}

func cacheProjection(_ db: Database, path: Data, viewRoot: Data) throws -> CacheProjection? {
    guard let row: Row = try Row.fetchOne(db, sql: "SELECT * FROM nodes WHERE path=?", arguments: [path]) else { return nil }
    var logical: Int64 = row["total_logical"]
    var allocated: Int64 = row["total_allocated"]
    var count: Int64 = row["total_count"]
    var directories: Int64 = row["directory_count"]
    var completed: Int64 = row["completed_count"]
    var work: Double = (row["progress"] as Double) * Double(directories)
    var revision: Int64 = row["scan_revision"]
    var date: Double = row["scan_date"]
    var scopes: [Data] = [path]
    var covered: [Data] = [viewRoot, path]
    var position: Int = 0
    while position < scopes.count {
        let scope: Data = scopes[position]
        position += 1
        let (lower, upper): (Data, Data) = cacheRange(scope)
        let aliases: [Row] = try Row.fetchAll(db, sql: "SELECT path,target FROM aliases WHERE path=? OR (path>=? AND path<?) ORDER BY length(target),target,path", arguments: [scope, lower, upper])
        for alias: Row in aliases {
            let target: Data = try resolveCacheAlias(db, path: alias["target"])
            if covered.contains(where: { cacheContains(target, in: $0) || cacheContains($0, in: target) }) { continue }
            guard let canonical: Row = try Row.fetchOne(db, sql: "SELECT * FROM nodes WHERE path=?", arguments: [target]),
                  let source: Row = try Row.fetchOne(db, sql: "SELECT * FROM nodes WHERE path=?", arguments: [alias["path"] as Data]) else {
                throw IndexError.malformedCache("Filesystem alias has no observed source or target")
            }
            logical += (canonical["total_logical"] as Int64) - (source["total_logical"] as Int64)
            allocated += (canonical["total_allocated"] as Int64) - (source["total_allocated"] as Int64)
            count += (canonical["total_count"] as Int64) - (source["total_count"] as Int64)
            directories += (canonical["directory_count"] as Int64) - (source["directory_count"] as Int64)
            completed += (canonical["completed_count"] as Int64) - (source["completed_count"] as Int64)
            work += (canonical["progress"] as Double) * Double(canonical["directory_count"] as Int64) - (source["progress"] as Double) * Double(source["directory_count"] as Int64)
            revision = max(revision, canonical["scan_revision"])
            date = max(date, canonical["scan_date"])
            covered.append(target)
            scopes.append(target)
        }
    }
    guard logical >= 0, allocated >= 0, count > 0 else { throw IndexError.malformedCache("Invalid filesystem alias totals") }
    let metrics: Data? = row["scan_metrics"]
    return CacheProjection(logical: UInt64(logical), allocated: UInt64(allocated), count: count, revision: revision, date: date,
        complete: directories == completed, progress: directories > 0 ? min(1, max(0, work / Double(directories))) : 0,
        metrics: try metrics.map { try JSONDecoder().decode(ScanMetrics.self, from: $0) } ?? emptyScanMetrics, scopes: scopes)
}

func projectCacheNode(_ db: Database, node: IndexedNode, viewRoot: Data) throws -> IndexedNode {
    guard let projection: CacheProjection = try cacheProjection(db, path: node.entry.path, viewRoot: viewRoot) else { return node }
    return IndexedNode(entry: node.entry, subtreeLogicalBytes: projection.logical, subtreeAllocatedBytes: projection.allocated,
        subtreeNodeCount: projection.count, aliasTargetPath: node.aliasTargetPath, lastOpenedDate: node.lastOpenedDate)
}

func cacheSummary(_ db: Database, root: String) throws -> IndexSummary? {
    let path: Data = try resolveCacheAlias(db, path: Data(root.utf8))
    guard let projection: CacheProjection = try cacheProjection(db, path: path, viewRoot: path) else { return nil }
    var issues: [ScanIssue] = []
    for scope: Data in projection.scopes {
        let (lower, upper): (Data, Data) = cacheRange(scope)
        let reports: [Data] = try Data.fetchAll(db, sql: "SELECT report FROM directories WHERE report IS NOT NULL AND (path=? OR (path>=? AND path<?)) AND json_array_length(CAST(report AS TEXT),'$.issues')>0", arguments: [scope, lower, upper])
        issues.append(contentsOf: try reports.flatMap { try JSONDecoder().decode(ScanSummary.self, from: $0).issues })
    }
    let blocking: Bool = issues.contains { ![.excluded, .directoryAlias, .mountBoundary].contains($0.kind) }
    return IndexSummary(root: root, logicalBytes: projection.logical, allocatedBytes: projection.allocated, nodeCount: projection.count,
        revision: projection.revision, lastScanDate: Date(timeIntervalSince1970: projection.date), isComplete: projection.complete && !blocking,
        issues: issues, metrics: projection.metrics)
}

func cacheProgress(_ db: Database, root: String, elapsed: Double) throws -> IndexProgress? {
    let path: Data = try resolveCacheAlias(db, path: Data(root.utf8))
    guard let projection: CacheProjection = try cacheProjection(db, path: path, viewRoot: path) else { return nil }
    return IndexProgress(entriesObserved: projection.count, logicalBytesObserved: projection.logical,
        allocatedBytesObserved: projection.allocated, elapsedSeconds: elapsed, previousNodeCount: projection.count,
        completionFraction: projection.progress * 0.95)
}

func pendingCacheDirectory(_ db: Database, root: Data) throws -> Data? {
    let resolved: Data = try resolveCacheAlias(db, path: root)
    guard let projection: CacheProjection = try cacheProjection(db, path: resolved, viewRoot: resolved) else { return nil }
    for scope: Data in projection.scopes {
        let (lower, upper): (Data, Data) = cacheRange(scope)
        if let pending: Data = try Data.fetchOne(db, sql: "SELECT path FROM directories WHERE done=0 AND (path=? OR (path>=? AND path<?)) ORDER BY length(path),path LIMIT 1", arguments: [scope, lower, upper]) { return pending }
    }
    return nil
}

func invalidateCacheListing(_ db: Database, path: Data) throws {
    let resolved: Data = try resolveCacheAlias(db, path: path)
    for directory: Data in Set([path, resolved]) {
        try db.execute(sql: "UPDATE directories SET done=0,report=NULL WHERE path=?", arguments: [directory])
        try db.execute(sql: "UPDATE nodes SET scan_revision=(SELECT revision FROM cache_state WHERE id=1) WHERE path=?", arguments: [directory])
        try markCacheAncestors(db, path: directory)
    }
}

func invalidateCacheSubtree(_ db: Database, path: Data) throws {
    let resolved: Data = try resolveCacheAlias(db, path: path)
    let (lower, upper): (Data, Data) = cacheRange(resolved)
    let paths: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM directories WHERE path=? OR (path>=? AND path<?)", arguments: [resolved, lower, upper])
    for directory: Data in paths { try invalidateCacheListing(db, path: directory) }
}

func migrateFilesystemCache(_ db: Database, pendingURL: URL) throws {
    let hasLegacy: Bool = try db.tableExists("roots")
    if hasLegacy {
        try db.execute(sql: """
            ALTER TABLE roots RENAME TO legacy_roots;
            ALTER TABLE nodes RENAME TO legacy_nodes;
            ALTER TABLE aliases RENAME TO legacy_aliases;
            ALTER TABLE git_cache RENAME TO legacy_git_cache;
            DROP INDEX node_children; DROP INDEX node_depth; DROP INDEX node_git_markers;
            """)
    }
    try createFilesystemCache(db)
    _ = try beginCacheChanges(db)
    if hasLegacy {
        let cursor: RowCursor = try Row.fetchCursor(db, sql: """
            SELECT n.* FROM legacy_nodes n LEFT JOIN legacy_roots r ON r.root=n.root
            ORDER BY COALESCE(json_extract(CAST(r.summary AS TEXT),'$.lastScanDate'),0),n.root,n.path
            """)
        var batch: [ScanEntry] = []
        while let row: Row = try cursor.next() {
            batch.append(ScanEntry(path: row["path"], parentPath: row["parent"], name: row["name"], metadata: try decodeMetadata(row["metadata"])))
            if batch.count == 512 {
                try recordCacheEntries(db, entries: batch, directory: nil, epoch: 0, revision: 1)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try recordCacheEntries(db, entries: batch, directory: nil, epoch: 0, revision: 1)
        try db.execute(sql: "UPDATE directories SET observed=1 WHERE path IN (SELECT path FROM legacy_nodes WHERE directory=1)")
        for row: Row in try Row.fetchAll(db, sql: "SELECT root,summary FROM legacy_roots") {
            let summary: IndexSummary = try JSONDecoder().decode(IndexSummary.self, from: row["summary"])
            if !summary.issues.isEmpty {
                let report: ScanSummary = ScanSummary(metrics: emptyScanMetrics, issues: summary.issues, aliases: [])
                try db.execute(sql: "UPDATE directories SET report=? WHERE path=?", arguments: [try JSONEncoder().encode(report), Data((row["root"] as String).utf8)])
            }
        }
        try db.execute(sql: "INSERT OR REPLACE INTO aliases(path,target,seen) SELECT path,target,seen FROM legacy_aliases ORDER BY root")
    }
    if FileManager.default.fileExists(atPath: pendingURL.path) {
        var configuration: Configuration = Configuration()
        configuration.readonly = true
        let pending: DatabaseQueue = try DatabaseQueue(path: pendingURL.path, configuration: configuration)
        try pending.read { legacy in
            guard try legacy.tableExists("entries") else { throw IndexError.malformedCache("Interrupted scan database has no entries table: \(pendingURL.path)") }
            let scans: [Row] = try Row.fetchAll(legacy, sql: "SELECT root,json_extract(CAST(identity AS TEXT),'$.revision') AS revision FROM scans")
            var eligible: Set<String> = []
            for scan: Row in scans {
                let root: String = scan["root"]
                let committed: Int64 = hasLegacy ? (try Int64.fetchOne(db, sql: "SELECT revision FROM legacy_roots WHERE root=?", arguments: [root]) ?? 0) : 0
                if scan["revision"] as Int64? == committed + 1 { eligible.insert(root) }
            }
            let cursor: RowCursor = try Row.fetchCursor(legacy, sql: "SELECT e.* FROM entries e JOIN scans s ON s.root=e.root ORDER BY e.id")
            var batch: [ScanEntry] = []
            while let row: Row = try cursor.next() {
                let root: String = row["root"]
                guard eligible.contains(root) else { continue }
                let metadata: FileMetadata = try decodeMetadata(row["metadata"])
                let saved: Data? = try Data.fetchOne(db, sql: "SELECT metadata FROM nodes WHERE path=?", arguments: [row["path"] as Data])
                if let saved {
                    let previous: FileTimestamp = try decodeMetadata(saved).changeTime
                    if previous.seconds > metadata.changeTime.seconds || (previous.seconds == metadata.changeTime.seconds && previous.nanoseconds > metadata.changeTime.nanoseconds) { continue }
                }
                batch.append(ScanEntry(path: row["path"], parentPath: row["parent"], name: row["name"], metadata: metadata))
                if batch.count == 512 {
                    try recordCacheEntries(db, entries: batch, directory: nil, epoch: 0, revision: 1)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            try recordCacheEntries(db, entries: batch, directory: nil, epoch: 0, revision: 1)
            if try legacy.tableExists("jobs") {
                let jobs: RowCursor = try Row.fetchCursor(legacy, sql: "SELECT j.root,j.path,j.report,e.metadata FROM jobs j JOIN entries e ON e.root=j.root AND e.path=j.path WHERE j.done=1")
                while let job: Row = try jobs.next() {
                    guard eligible.contains(job["root"]) else { continue }
                    let path: Data = job["path"]
                    let metadata: Data? = try Data.fetchOne(db, sql: "SELECT metadata FROM nodes WHERE path=?", arguments: [path])
                    guard metadata == job["metadata"] as Data else { continue }
                    let report: Data? = job["report"]
                    try db.execute(sql: "UPDATE directories SET observed=1,report=? WHERE path=?", arguments: [report, path])
                    if let report {
                        for alias: ScanAlias in try JSONDecoder().decode(ScanSummary.self, from: report).aliases {
                            try db.execute(sql: "INSERT OR REPLACE INTO aliases VALUES(?,?,0)", arguments: [alias.aliasPath, alias.targetPath])
                        }
                    }
                }
            }
        }
    }
    let disconnected: [Data] = try Data.fetchAll(db, sql: "SELECT DISTINCT parent FROM nodes WHERE parent IS NOT NULL AND parent NOT IN (SELECT path FROM nodes)")
    for path: Data in disconnected {
        var parent: Data? = path
        while let current: Data = parent {
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM nodes WHERE path=?)", arguments: [current])! { break }
            let metadata: FileMetadata
            do { metadata = try DirectoryScanner.directoryMetadata(path: current) }
            catch ScanError.systemCall(_, _, let code) where [ENOENT, ENOTDIR, EACCES, EPERM].contains(code) { break }
            let name: Data = current == Data("/".utf8) ? current : Data(current.split(separator: 47).last!)
            try recordCacheEntries(db, entries: [ScanEntry(path: current, parentPath: cacheParent(current), name: name, metadata: metadata)], directory: nil, epoch: 0, revision: 1)
            parent = cacheParent(current)
        }
    }
    try rebuildCacheTotals(db)
    if hasLegacy {
        for row: Row in try Row.fetchAll(db, sql: "SELECT root,summary FROM legacy_roots") {
            let summary: IndexSummary = try JSONDecoder().decode(IndexSummary.self, from: row["summary"])
            try db.execute(sql: "UPDATE nodes SET scan_date=?,scan_metrics=? WHERE path=?", arguments: [summary.lastScanDate.timeIntervalSince1970, try JSONEncoder().encode(summary.metrics), Data((row["root"] as String).utf8)])
        }
        try db.execute(sql: "DROP TABLE legacy_roots; DROP TABLE legacy_nodes; DROP TABLE legacy_aliases; DROP TABLE legacy_git_cache")
    }
    try db.execute(sql: "UPDATE cache_state SET revision=1; PRAGMA user_version=2")
}
