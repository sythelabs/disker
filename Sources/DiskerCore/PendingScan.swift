import Darwin
import Foundation
import GRDB

private struct PendingScanIdentity: Codable, Equatable {
    let revision: Int64
    let device: UInt64
    let inode: UInt64
    let birthTime: FileTimestamp
    let mountPolicy: MountPolicy
    let exclusions: [Data]
}

private struct PendingDirectory {
    let path: Data
    let weight: Double
}

// The caller holds the index writer lock throughout traversal and promotion.
final class PendingScan: Sendable {
    private let pool: DatabasePool
    private let root: String
    private let rootPath: Data

    init(databaseURL: URL, root: String) throws {
        self.root = root
        rootPath = Data(root.utf8)
        var configuration: Configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous=FULL") }
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS scans(root TEXT PRIMARY KEY, identity BLOB NOT NULL,
                    checkpoint BLOB, fraction REAL NOT NULL, count INTEGER NOT NULL,
                    logical INTEGER NOT NULL, allocated INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, root TEXT NOT NULL,
                    path BLOB NOT NULL, parent BLOB, name BLOB NOT NULL, metadata BLOB NOT NULL,
                    logical INTEGER NOT NULL, allocated INTEGER NOT NULL, directory INTEGER NOT NULL, UNIQUE(root,path));
                CREATE INDEX IF NOT EXISTS entry_parent ON entries(root,parent,directory);
                CREATE INDEX IF NOT EXISTS entry_stream ON entries(root,id);
                CREATE TABLE IF NOT EXISTS jobs(id INTEGER PRIMARY KEY, root TEXT NOT NULL,
                    path BLOB NOT NULL, weight REAL NOT NULL, done INTEGER NOT NULL,
                    parent BLOB, report BLOB, device INTEGER, inode INTEGER, UNIQUE(root,path));
                CREATE INDEX IF NOT EXISTS pending_jobs ON jobs(root,done,id);
                CREATE INDEX IF NOT EXISTS job_parent ON jobs(root,parent);
                CREATE INDEX IF NOT EXISTS visited_jobs ON jobs(root,device,inode) WHERE done=1;
                """)
        }
    }

    func checkpoint(revision: Int64, metadata: FileMetadata, options: ScanOptions) throws -> JournalCheckpoint? {
        let identity: PendingScanIdentity = PendingScanIdentity(revision: revision, device: metadata.device,
            inode: metadata.inode, birthTime: metadata.birthTime, mountPolicy: options.mountPolicy, exclusions: options.excludedPaths)
        return try pool.write { db in
            guard let row: Row = try Row.fetchOne(db, sql: "SELECT identity,checkpoint FROM scans WHERE root=?", arguments: [root]) else { return nil }
            guard try JSONDecoder().decode(PendingScanIdentity.self, from: row["identity"]) == identity else {
                try discard(db: db)
                return nil
            }
            let data: Data? = row["checkpoint"]
            return try data.map { try JSONDecoder().decode(JournalCheckpoint.self, from: $0) }
        }
    }

    func exists() throws -> Bool {
        try pool.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM scans WHERE root=?)", arguments: [root])! }
    }

    func prepare(revision: Int64, metadata: FileMetadata, options: ScanOptions, replay: JournalReplay) throws {
        let identity: PendingScanIdentity = PendingScanIdentity(revision: revision, device: metadata.device,
            inode: metadata.inode, birthTime: metadata.birthTime, mountPolicy: options.mountPolicy, exclusions: options.excludedPaths)
        try pool.write { db in
            if replay.requiresFullScan { try discard(db: db) }
            let present: Bool = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM scans WHERE root=?)", arguments: [root])!
            if !present {
                try db.execute(sql: "INSERT INTO scans VALUES(?,?,?,0,0,0,0)", arguments: [root, try JSONEncoder().encode(identity), try replay.checkpoint.map { try JSONEncoder().encode($0) }])
                try db.execute(sql: "INSERT INTO jobs(root,path,weight,done) VALUES(?,?,1,0)", arguments: [root, rootPath])
            } else {
                // Invalidations and their cursor commit together, so a crash cannot skip an edit.
                for path: String in replay.recursiveDirectories {
                    let bytes: Data = Data(path.utf8)
                    try removeDescendants(db: db, path: bytes)
                    try invalidate(db: db, path: bytes)
                    if bytes != rootPath { try invalidate(db: db, path: pendingParent(bytes)) }
                }
                for path: String in replay.dirtyDirectories { try invalidate(db: db, path: Data(path.utf8)) }
                let retryPaths: [Data] = try Data.fetchAll(db, sql: """
                    SELECT path FROM jobs WHERE root=? AND done=1 AND EXISTS(
                        SELECT 1 FROM json_each(CAST(jobs.report AS TEXT),'$.issues')
                        WHERE json_extract(value,'$.kind') IN
                            ('permissionDenied','vanished','metadataUnavailable','ioError','changedDuringScan'))
                    """, arguments: [root])
                for path: Data in retryPaths { try invalidate(db: db, path: path) }
                try db.execute(sql: "UPDATE scans SET checkpoint=? WHERE root=?", arguments: [try replay.checkpoint.map { try JSONEncoder().encode($0) }, root])
            }
        }
    }

    func run(options: ScanOptions, metadata: FileMetadata, previousNodeCount: Int64?, start: ContinuousClock.Instant,
             receiveEvent: @Sendable (IndexEvent) -> Void, isCancelled: @Sendable () -> Bool) throws -> ScanSummary {
        try pool.read { db in try publishProgress(db: db, previousNodeCount: previousNodeCount, start: start, receiveEvent: receiveEvent) }
        try replay(isCancelled: isCancelled) { receiveEvent(.batch($0)) }
        return try pool.writeWithoutTransaction { db in
            var metrics: ScanMetrics = metricsZero()
            var uncommittedEntries: Int = 0
            var lastCheckpoint: ContinuousClock.Instant = .now
            try db.beginTransaction(.immediate)
            func checkpoint() throws {
                try db.commit()
                try db.beginTransaction(.immediate)
                uncommittedEntries = 0
                lastCheckpoint = .now
            }
            do {
                while let job: PendingDirectory = try nextJob(db: db) {
                    if isCancelled() { throw ScanError.cancelled }
                    let summary: ScanSummary
                    var opened: FileMetadata? = nil
                    do {
                        let live: FileMetadata = try DirectoryScanner.directoryMetadata(path: job.path)
                        metrics.metadataCalls += 1
                        let alias: Data? = try Data.fetchOne(db, sql: "SELECT path FROM jobs WHERE root=? AND done=1 AND device=? AND inode=? AND path<>? ORDER BY id LIMIT 1", arguments: [root, Int64(bitPattern: live.device), Int64(bitPattern: live.inode), job.path])
                        if options.mountPolicy == .sameDevice && live.device != metadata.device {
                            summary = ScanSummary(metrics: metricsZero(), issues: [ScanIssue(kind: .mountBoundary, path: job.path, operation: "descend", errnoCode: 0)], aliases: [])
                        } else if let alias {
                            summary = ScanSummary(metrics: metricsZero(), issues: [ScanIssue(kind: .directoryAlias, path: job.path, operation: "descend", errnoCode: 0)], aliases: [ScanAlias(aliasPath: job.path, targetPath: alias)])
                        } else {
                            try removeEntries(db: db, predicate: "parent=?", paths: [job.path])
                            summary = try DirectoryScanner.enumerateDirectory(path: job.path, options: options, isCancelled: isCancelled, receiveProgress: { _ in }) { batch in
                                try save(db: db, batch: batch)
                                uncommittedEntries += batch.count
                                if uncommittedEntries >= 4096 || lastCheckpoint.duration(to: .now) >= .milliseconds(250) {
                                    try checkpoint()
                                }
                                receiveEvent(.batch(batch))
                                try publishProgress(db: db, previousNodeCount: previousNodeCount, start: start, receiveEvent: receiveEvent)
                            }
                            opened = live
                            metrics = pendingMetrics(metrics, summary.metrics)
                        }
                    } catch ScanError.systemCall(let path, let operation, let code) where job.path != rootPath {
                        opened = nil
                        if code == ENOENT || code == ENOTDIR {
                            try removeDescendants(db: db, path: job.path)
                            try invalidate(db: db, path: pendingParent(job.path))
                        }
                        let kind: ScanIssueKind = (code == EACCES || code == EPERM) ? .permissionDenied : ((code == ENOENT || code == ENOTDIR) ? .vanished : .ioError)
                        summary = ScanSummary(metrics: metricsZero(), issues: [ScanIssue(kind: kind, path: path, operation: operation, errnoCode: code)], aliases: [])
                    }
                    try seal(db: db, job: job, summary: summary, metadata: opened)
                    try checkpoint()
                    try publishProgress(db: db, previousNodeCount: previousNodeCount, start: start, receiveEvent: receiveEvent)
                }
                if isCancelled() { throw ScanError.cancelled }
                try db.commit()
            } catch ScanError.cancelled {
                try db.commit()
                throw ScanError.cancelled
            } catch {
                try db.rollback()
                throw error
            }
            var issues: [ScanIssue] = []
            var aliases: [ScanAlias] = []
            let cursor: DatabaseValueCursor<Data> = try Data.fetchCursor(db, sql: "SELECT report FROM jobs WHERE root=? AND done=1", arguments: [root])
            while let data: Data = try cursor.next() {
                let report: ScanSummary = try JSONDecoder().decode(ScanSummary.self, from: data)
                issues += report.issues
                aliases += report.aliases
            }
            return ScanSummary(metrics: metrics, issues: issues, aliases: aliases)
        }
    }

    func replay(isCancelled: @Sendable () -> Bool, receiveBatch: ([ScanEntry]) throws -> Void) throws {
        var lastID: Int64 = 0
        while true {
            if isCancelled() { throw ScanError.cancelled }
            let rows: [Row] = try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id,path,parent,name,metadata FROM entries WHERE root=? AND id>? ORDER BY id LIMIT 512", arguments: [root, lastID])
            }
            if rows.isEmpty { return }
            let entries: [ScanEntry] = try rows.map { row in
                ScanEntry(path: row["path"], parentPath: row["parent"], name: row["name"], metadata: try decodeMetadata(row["metadata"]))
            }
            try receiveBatch(entries)
            lastID = rows.last!["id"]
        }
    }

    func discard() throws { try pool.write { db in try discard(db: db) } }

    private func discard(db: Database) throws {
        try db.execute(sql: "DELETE FROM entries WHERE root=?; DELETE FROM jobs WHERE root=?; DELETE FROM scans WHERE root=?", arguments: [root, root, root])
    }

    private func nextJob(db: Database) throws -> PendingDirectory? {
        guard let row: Row = try Row.fetchOne(db, sql: "SELECT path,weight FROM jobs WHERE root=? AND done=0 ORDER BY id LIMIT 1", arguments: [root]) else { return nil }
        return PendingDirectory(path: row["path"], weight: row["weight"])
    }

    private func save(db: Database, batch: [ScanEntry]) throws {
        let statement: Statement = try db.makeStatement(sql: "INSERT INTO entries(root,path,parent,name,metadata,logical,allocated,directory) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(root,path) DO UPDATE SET parent=excluded.parent,name=excluded.name,metadata=excluded.metadata,logical=excluded.logical,allocated=excluded.allocated,directory=excluded.directory")
        let previousEntry: Statement = try db.makeStatement(sql: "SELECT logical,allocated FROM entries WHERE root=? AND path=?")
        var count: Int64 = 0
        var logicalChange: Int64 = 0
        var allocatedChange: Int64 = 0
        for entry: ScanEntry in batch {
            let logical: UInt64 = entry.metadata.kind == .directory ? 0 : entry.metadata.logicalBytes
            guard logical <= Int64.max, entry.metadata.allocatedBytes <= Int64.max else { throw IndexError.malformedCache("File size exceeds SQLite integer range") }
            let parent: Data? = entry.path == rootPath ? nil : (entry.parentPath ?? pendingParent(entry.path))
            let previous: Row? = try Row.fetchOne(previousEntry, arguments: [root, entry.path])
            if previous == nil { count += 1 }
            logicalChange += Int64(logical) - (previous?["logical"] as Int64? ?? 0)
            allocatedChange += Int64(entry.metadata.allocatedBytes) - (previous?["allocated"] as Int64? ?? 0)
            try statement.execute(arguments: [root, entry.path, parent, entry.name, encodeMetadata(entry.metadata), Int64(logical), Int64(entry.metadata.allocatedBytes), entry.metadata.kind == .directory])
        }
        try db.execute(sql: "UPDATE scans SET count=count+?,logical=logical+?,allocated=allocated+? WHERE root=?", arguments: [count, logicalChange, allocatedChange, root])
    }

    private func seal(db: Database, job: PendingDirectory, summary: ScanSummary, metadata: FileMetadata?) throws {
        let count: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE root=? AND parent=? AND directory=1", arguments: [root, job.path])!
        let weight: Double = job.weight / Double(count + 1)
        try db.execute(sql: "INSERT OR IGNORE INTO jobs(root,path,weight,done,parent) SELECT root,path,?,0,parent FROM entries INDEXED BY entry_parent WHERE root=? AND parent=? AND directory=1 ORDER BY path", arguments: [weight, root, job.path])
        // Prune directories removed or replaced during a resumed enumeration.
        let obsolete: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM jobs WHERE root=? AND parent=? AND NOT EXISTS(SELECT 1 FROM entries e WHERE e.root=jobs.root AND e.path=jobs.path AND e.directory=1)", arguments: [root, job.path])
        for path: Data in obsolete { try removeDescendants(db: db, path: path); try db.execute(sql: "DELETE FROM jobs WHERE root=? AND path=?", arguments: [root, path]) }
        try db.execute(sql: "UPDATE jobs SET done=1,report=?,device=?,inode=? WHERE root=? AND path=?", arguments: [try JSONEncoder().encode(summary), metadata.map { Int64(bitPattern: $0.device) }, metadata.map { Int64(bitPattern: $0.inode) }, root, job.path])
        try db.execute(sql: "UPDATE scans SET fraction=MIN(?,fraction+?) WHERE root=?", arguments: [Double(1).nextDown, weight, root])
    }

    private func invalidate(db: Database, path: Data) throws {
        try db.execute(sql: "UPDATE jobs SET weight=CASE WHEN done=1 THEN 0 ELSE weight END,done=0,report=NULL,device=NULL,inode=NULL WHERE root=? AND path=?", arguments: [root, path])
    }

    private func removeDescendants(db: Database, path: Data) throws {
        let prefix: Data = path.last == 47 ? path : path + Data([47])
        var upper: Data = prefix
        upper[upper.count - 1] = 48
        try removeEntries(db: db, predicate: "path>=? AND path<?", paths: [prefix, upper])
        try db.execute(sql: "DELETE FROM jobs WHERE root=? AND path>=? AND path<?", arguments: [root, prefix, upper])
    }

    private func removeEntries(db: Database, predicate: String, paths: [Data]) throws {
        let arguments: StatementArguments = StatementArguments([root]) + StatementArguments(paths)
        let removed: Row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count,COALESCE(SUM(logical),0) AS logical,COALESCE(SUM(allocated),0) AS allocated FROM entries WHERE root=? AND \(predicate)", arguments: arguments)!
        try db.execute(sql: "UPDATE scans SET count=count-?,logical=logical-?,allocated=allocated-? WHERE root=?", arguments: [removed["count"] as Int64, removed["logical"] as Int64, removed["allocated"] as Int64, root])
        try db.execute(sql: "DELETE FROM entries WHERE root=? AND \(predicate)", arguments: arguments)
    }

    private func publishProgress(db: Database, previousNodeCount: Int64?, start: ContinuousClock.Instant, receiveEvent: @Sendable (IndexEvent) -> Void) throws {
        guard let row: Row = try Row.fetchOne(db, sql: "SELECT count,logical,allocated,fraction FROM scans WHERE root=?", arguments: [root]) else {
            throw IndexError.malformedCache("Pending scan progress missing for root: \(root)")
        }
        let fraction: Double = row["fraction"]
        let elapsed: Duration = start.duration(to: .now)
        let progress: IndexProgress = IndexProgress(entriesObserved: row["count"], logicalBytesObserved: UInt64(row["logical"] as Int64), allocatedBytesObserved: UInt64(row["allocated"] as Int64), elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, previousNodeCount: previousNodeCount, completionFraction: fraction * 0.95)
        receiveEvent(.progress(progress))
    }
}

private func pendingParent(_ path: Data) -> Data {
    guard let slash: Data.Index = path.lastIndex(of: 47), slash > path.startIndex else { return Data("/".utf8) }
    return Data(path[..<slash])
}

private func metricsZero() -> ScanMetrics { ScanMetrics(entries: 0, directories: 0, bulkCalls: 0, metadataCalls: 0, contentBytesRead: 0) }

private func pendingMetrics(_ left: ScanMetrics, _ right: ScanMetrics) -> ScanMetrics {
    ScanMetrics(entries: left.entries + right.entries, directories: left.directories + right.directories, bulkCalls: left.bulkCalls + right.bulkCalls, metadataCalls: left.metadataCalls + right.metadataCalls, contentBytesRead: left.contentBytesRead + right.contentBytesRead)
}
