import Darwin
import Foundation
import GRDB

public actor DiskIndex {
    private let pool: DatabasePool
    private let cacheDirectories: [Data]

    public init(databaseURL: URL) throws {
        let directory: URL = databaseURL.deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory: String = directory.resolvingSymlinksInPath().path
        cacheDirectories = [Data(directory.path.utf8), Data(resolvedDirectory.utf8), Data(try physicalDirectoryPath(resolvedDirectory).utf8)]
        var configuration: Configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous=FULL")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        let version: Int32 = try pool.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
        guard version == 0 || version == 1 else { throw IndexError.incompatibleSchema(version) }
        if version == 0 {
            try pool.write { db in
                let currentVersion: Int32 = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                guard currentVersion == 0 || currentVersion == 1 else { throw IndexError.incompatibleSchema(currentVersion) }
                guard currentVersion == 0 else { return }
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS roots (
                        root TEXT PRIMARY KEY, revision INTEGER NOT NULL, summary BLOB NOT NULL, checkpoint BLOB
                    );
                    CREATE TABLE IF NOT EXISTS nodes (
                        root TEXT NOT NULL, path BLOB NOT NULL, parent BLOB, name BLOB NOT NULL,
                        depth INTEGER NOT NULL, directory INTEGER NOT NULL, metadata BLOB NOT NULL,
                        logical INTEGER NOT NULL, allocated INTEGER NOT NULL,
                        total_logical INTEGER NOT NULL, total_allocated INTEGER NOT NULL,
                        total_count INTEGER NOT NULL, seen INTEGER NOT NULL,
                        modified_revision INTEGER NOT NULL, total_revision INTEGER NOT NULL,
                        PRIMARY KEY (root, path)
                    ) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS node_children ON nodes(root, parent, total_allocated DESC, name);
                    CREATE INDEX IF NOT EXISTS node_depth ON nodes(root, depth);
                    CREATE INDEX IF NOT EXISTS node_git_markers ON nodes(root, name);
                    CREATE TABLE IF NOT EXISTS aliases (
                        root TEXT NOT NULL, path BLOB NOT NULL, target BLOB NOT NULL, seen INTEGER NOT NULL,
                        PRIMARY KEY(root,path)
                    ) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS git_cache (
                        root TEXT NOT NULL, path TEXT NOT NULL, revision INTEGER NOT NULL,
                        fingerprint BLOB NOT NULL, info BLOB NOT NULL, PRIMARY KEY(root, path)
                    ) WITHOUT ROWID;
                    PRAGMA user_version=1;
                    """)
            }
        }
    }

    public nonisolated func cachedSummary(root: String) async throws -> IndexSummary? {
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in try loadSummary(db: db, root: normalized) }
    }

    public nonisolated func node(root: String, path: Data) async throws -> IndexedNode? {
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in
            let query: String = "SELECT *, (SELECT target FROM aliases a WHERE a.root=nodes.root AND a.path=nodes.path) AS alias_target FROM nodes WHERE root=? AND path=?"
            if let row: Row = try Row.fetchOne(db, sql: query, arguments: [normalized, path]) { return try decodeNode(row) }
            let resolved: Data = try resolveAliasPath(db: db, root: normalized, path: path)
            guard let row: Row = try Row.fetchOne(db, sql: query, arguments: [normalized, resolved]) else { return nil }
            return try decodeNode(row)
        }
    }

    public nonisolated func children(root: String, directory: Data, offset: Int, limit: Int) async throws -> [IndexedNode] {
        guard offset >= 0, limit > 0, limit <= 10_000 else { throw IndexError.invalidQuery("offset must be >= 0 and limit must be 1 through 10000") }
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in
            let resolved: Data = try resolveAliasPath(db: db, root: normalized, path: directory)
            return try Row.fetchAll(db, sql: "SELECT *, (SELECT target FROM aliases a WHERE a.root=nodes.root AND a.path=nodes.path) AS alias_target FROM nodes INDEXED BY node_children WHERE root=? AND parent=? ORDER BY total_allocated DESC, name LIMIT ? OFFSET ?", arguments: [normalized, resolved, limit, offset]).map { try decodeNode($0) }
        }
    }

    public nonisolated func gitCandidates(root: String, offset: Int, limit: Int) async throws -> [String] {
        guard offset >= 0, limit > 0, limit <= 10_000 else { throw IndexError.invalidQuery("Invalid Git candidate page") }
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in
            let paths: [Data] = try Data.fetchAll(db, sql: "SELECT parent FROM nodes WHERE root=? AND name=? ORDER BY path LIMIT ? OFFSET ?", arguments: [normalized, Data(".git".utf8), limit, offset])
            return try paths.map { path in
                guard let value: String = String(data: path, encoding: .utf8) else { throw IndexError.invalidQuery("Git requires a UTF-8 repository path") }
                return value
            }
        }
    }

    public func gitInfo(root: String, path: String, inspector: GitInspector) async throws -> CachedGitInfo? {
        let normalized: String = normalizedRoot(root)
        guard let summary: IndexSummary = try await cachedSummary(root: normalized) else { throw IndexError.invalidQuery("Scan this root before Git enrichment") }
        let fingerprint: GitInputFingerprint? = try await Task.detached(priority: .utility) {
            try inspector.fingerprint(path: path)
        }.value
        guard let fingerprint else { return nil }
        let canonicalRoot: String = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path
        let repositoryPath: String
        if fingerprint.rootPath == canonicalRoot {
            repositoryPath = normalized
        } else if fingerprint.rootPath.hasPrefix(canonicalRoot == "/" ? "/" : canonicalRoot + "/") {
            repositoryPath = normalized + (canonicalRoot == "/" ? "/" : "") + String(fingerprint.rootPath.dropFirst(canonicalRoot.count))
        } else {
            throw IndexError.invalidQuery("Repository is outside the indexed root: \(fingerprint.rootPath)")
        }
        let snapshotRevision: Int64 = try await pool.read { db in
            guard let revision: Int64 = try Int64.fetchOne(db, sql: "SELECT total_revision FROM nodes WHERE root=? AND path=?", arguments: [normalized, Data(repositoryPath.utf8)]) else { throw IndexError.invalidQuery("Repository is absent from the cached tree: \(repositoryPath)") }
            return revision
        }
        let cached: GitRepositoryInfo? = try await pool.read { db in
            guard let row: Row = try Row.fetchOne(db, sql: "SELECT revision,fingerprint,info FROM git_cache WHERE root=? AND path=?", arguments: [normalized, repositoryPath]), row["revision"] as Int64 == snapshotRevision else { return nil }
            let saved: GitInputFingerprint = try JSONDecoder().decode(GitInputFingerprint.self, from: row["fingerprint"])
            guard saved == fingerprint else { return nil }
            return try JSONDecoder().decode(GitRepositoryInfo.self, from: row["info"])
        }
        if let cached {
            guard try await cachedSummary(root: normalized)?.revision == summary.revision else { throw IndexError.staleEnrichment(repositoryPath) }
            return CachedGitInfo(info: cached, wasCached: true)
        }
        let enriched: (GitRepositoryInfo?, GitInputFingerprint?) = try await Task.detached(priority: .utility) {
            (try inspector.inspect(path: path), try inspector.fingerprint(path: path))
        }.value
        guard let info: GitRepositoryInfo = enriched.0 else { return nil }
        guard enriched.1 == fingerprint, try await cachedSummary(root: normalized)?.revision == summary.revision else { throw IndexError.staleEnrichment(repositoryPath) }
        try await pool.write { db in
            let currentRevision: Int64? = try Int64.fetchOne(db, sql: "SELECT total_revision FROM nodes WHERE root=? AND path=?", arguments: [normalized, Data(repositoryPath.utf8)])
            guard currentRevision == snapshotRevision else { throw IndexError.staleEnrichment(repositoryPath) }
            guard try Int64.fetchOne(db, sql: "SELECT revision FROM roots WHERE root=?", arguments: [normalized]) == summary.revision else { throw IndexError.staleEnrichment(repositoryPath) }
            try db.execute(sql: "INSERT INTO git_cache(root,path,revision,fingerprint,info) VALUES(?,?,?,?,?) ON CONFLICT(root,path) DO UPDATE SET revision=excluded.revision,fingerprint=excluded.fingerprint,info=excluded.info", arguments: [normalized, repositoryPath, snapshotRevision, try JSONEncoder().encode(fingerprint), try JSONEncoder().encode(info)])
        }
        return CachedGitInfo(info: info, wasCached: false)
    }

    public func refresh(root: String, mode: RefreshMode, receiveEvent: @escaping @Sendable (IndexEvent) -> Void, isCancelled: @escaping @Sendable () -> Bool) async throws -> IndexSummary {
        let normalized: String = normalizedRoot(root)
        if case .directories(let directories) = mode {
            let rootPath: Data = Data(normalized.utf8)
            guard directories.allSatisfy({ $0 == rootPath || isDescendant($0, of: rootPath) }) else {
                throw IndexError.invalidQuery("Changed directories must be inside the indexed root: \(normalized)")
            }
        }
        let cachedAtStart: IndexSummary? = try await cachedSummary(root: normalized)
        receiveEvent(.started(cached: cachedAtStart))
        if isCancelled() { throw ScanError.cancelled }
        let exclusions: [Data] = cacheDirectories
        let options: ScanOptions = ScanOptions(batchSize: 512, bufferSize: 256 * 1024, mountPolicy: normalized == "/" ? .crossDevices : .sameDevice, excludedPaths: exclusions)
        let start: ContinuousClock.Instant = ContinuousClock.now
        let result: IndexSummary = try await pool.write { db in
            let cached: IndexSummary? = try loadSummary(db: db, root: normalized)
            let revision: Int64 = (cached?.revision ?? 0) + 1
            let checkpointData: Data? = try Data.fetchOne(db, sql: "SELECT checkpoint FROM roots WHERE root=?", arguments: [normalized])
            let checkpoint: JournalCheckpoint? = try checkpointData.map { try JSONDecoder().decode(JournalCheckpoint.self, from: $0) }
            let journal: FileEventJournal
            do {
                journal = try FileEventJournal(rootPath: normalized, checkpoint: checkpoint, latency: 0.05)
            } catch FileEventJournalError.filesystem(let operation, let path, let code) {
                throw ScanError.systemCall(path: Data(path.utf8), operation: operation, errnoCode: code)
            }
            defer { journal.stop() }
            let replay: JournalReplay = try journal.replay(timeout: 10)
            var rootChanged: Bool = false
            if let previous: Data = try Data.fetchOne(db, sql: "SELECT metadata FROM nodes WHERE root=? AND path=?", arguments: [normalized, Data(normalized.utf8)]) {
                let saved: FileMetadata = try decodeMetadata(previous)
                var live: stat = stat()
                guard stat(normalized, &live) == 0 else { throw ScanError.systemCall(path: Data(normalized.utf8), operation: "stat", errnoCode: errno) }
                rootChanged = saved.device != UInt64(UInt32(bitPattern: live.st_dev)) || saved.inode != UInt64(live.st_ino) || saved.birthTime.seconds != Int64(live.st_birthtimespec.tv_sec) || saved.birthTime.nanoseconds != Int32(live.st_birthtimespec.tv_nsec)
            }
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS dirty(path BLOB PRIMARY KEY, depth INTEGER NOT NULL) WITHOUT ROWID; DELETE FROM dirty")
            var metrics: ScanMetrics = ScanMetrics(entries: 0, directories: 0, bulkCalls: 0, metadataCalls: 0, contentBytesRead: 0)
            var issues: [ScanIssue] = []
            var observed: Int64 = 0
            var logicalObserved: UInt64 = 0
            var allocatedObserved: UInt64 = 0
            var currentCheckpoint: JournalCheckpoint? = replay.checkpoint
            let upsert: Statement = try db.makeStatement(sql: """
                INSERT INTO nodes(root,path,parent,name,depth,directory,metadata,logical,allocated,total_logical,total_allocated,total_count,seen,modified_revision,total_revision)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
                ON CONFLICT(root,path) DO UPDATE SET parent=excluded.parent,name=excluded.name,depth=excluded.depth,
                    directory=excluded.directory,metadata=excluded.metadata,logical=excluded.logical,
                    allocated=excluded.allocated,seen=excluded.seen,
                    total_logical=CASE WHEN excluded.directory=0 THEN excluded.logical ELSE nodes.total_logical END,
                    total_allocated=CASE WHEN excluded.directory=0 THEN excluded.allocated ELSE nodes.total_allocated END,
                    total_count=CASE WHEN excluded.directory=0 THEN 1 ELSE nodes.total_count END,
                    modified_revision=CASE WHEN substr(nodes.metadata,1,120)<>substr(excluded.metadata,1,120) OR substr(nodes.metadata,137)<>substr(excluded.metadata,137) THEN excluded.modified_revision ELSE nodes.modified_revision END,
                    total_revision=CASE WHEN excluded.directory=0 AND (substr(nodes.metadata,1,120)<>substr(excluded.metadata,1,120) OR substr(nodes.metadata,137)<>substr(excluded.metadata,137)) THEN excluded.total_revision ELSE nodes.total_revision END
                """)
            let markDirty: Statement = try db.makeStatement(sql: "INSERT OR IGNORE INTO dirty(path,depth) VALUES(?,?)")
            let previousDirectory: Statement = try db.makeStatement(sql: "SELECT directory FROM nodes WHERE root=? AND path=?")
            func apply(_ batch: [ScanEntry]) throws {
                for entry: ScanEntry in batch {
                    let directory: Bool = entry.metadata.kind == .directory
                    let logical: UInt64 = directory ? 0 : entry.metadata.logicalBytes
                    guard logical <= Int64.max, entry.metadata.allocatedBytes <= Int64.max else { throw IndexError.malformedCache("File size exceeds SQLite integer range") }
                    if !directory, let wasDirectory: Bool = try Bool.fetchOne(previousDirectory, arguments: [normalized, entry.path]), wasDirectory {
                        let (lower, upper): (Data, Data) = prefixRange(entry.path)
                        try db.execute(sql: "DELETE FROM nodes WHERE root=? AND path>=? AND path<?", arguments: [normalized, lower, upper])
                        try db.execute(sql: "DELETE FROM aliases WHERE root=? AND (path=? OR (path>=? AND path<?) OR target=? OR (target>=? AND target<?))", arguments: [normalized, entry.path, lower, upper, entry.path, lower, upper])
                        issues.removeAll { $0.path == entry.path || isDescendant($0.path, of: entry.path) }
                    }
                    let parent: Data? = entry.path == Data(normalized.utf8) ? nil : (entry.parentPath ?? parentPath(entry.path))
                    try upsert.execute(arguments: [normalized, entry.path, parent, entry.name, pathDepth(entry.path), directory, encodeMetadata(entry.metadata), Int64(logical), Int64(entry.metadata.allocatedBytes), Int64(logical), Int64(entry.metadata.allocatedBytes), revision, revision, revision])
                    if directory { try markDirty.execute(arguments: [entry.path, pathDepth(entry.path)]) }
                    if let parent { try markDirty.execute(arguments: [parent, pathDepth(parent)]) }
                    observed += 1
                    logicalObserved += logical
                    allocatedObserved += entry.metadata.allocatedBytes
                }
                receiveEvent(.batch(batch))
                receiveEvent(.progress(IndexProgress(entriesObserved: observed, logicalBytesObserved: logicalObserved, allocatedBytesObserved: allocatedObserved, elapsedSeconds: elapsedSeconds(start), previousNodeCount: cached?.nodeCount)))
            }
            func scanTree(_ path: Data) throws {
                try resetSeen(db: db, root: normalized, path: path)
                let summary: ScanSummary
                do {
                    summary = try DirectoryScanner.scan(root: path, options: options, isCancelled: isCancelled, receiveBatch: apply)
                } catch ScanError.systemCall(_, _, let code) where (code == ENOENT || code == ENOTDIR) && path != Data(normalized.utf8) {
                    try scanDirectory(parentPath(path))
                    return
                } catch ScanError.systemCall(let failedPath, let operation, let code) where (code == EACCES || code == EPERM) && path != Data(normalized.utf8) {
                    let issue: ScanIssue = ScanIssue(kind: .permissionDenied, path: failedPath, operation: operation, errnoCode: code)
                    issues.removeAll { $0.path == failedPath }
                    issues.append(issue)
                    try preserveUnreachable(db: db, root: normalized, issues: [issue], revision: revision)
                    return
                }
                metrics = addMetrics(metrics, summary.metrics)
                issues.removeAll { $0.path == path || isDescendant($0.path, of: path) }
                issues += summary.issues
                for alias: ScanAlias in summary.aliases {
                    try db.execute(sql: "INSERT INTO aliases(root,path,target,seen) VALUES(?,?,?,?) ON CONFLICT(root,path) DO UPDATE SET target=excluded.target,seen=excluded.seen", arguments: [normalized, alias.aliasPath, alias.targetPath, revision])
                }
                try preserveUnreachable(db: db, root: normalized, issues: summary.issues, revision: revision)
                try markRemovedParents(db: db, root: normalized, path: path, revision: revision)
                try removeUnseen(db: db, root: normalized, path: path, revision: revision)
                try markAncestors(db: db, path: path, rootPath: Data(normalized.utf8))
            }
            func scanDirectory(_ path: Data) throws {
                if exclusions.contains(where: { excludedPath(path, directory: $0) }) { return }
                let existing: Row? = try Row.fetchOne(db, sql: "SELECT directory FROM nodes WHERE root=? AND path=?", arguments: [normalized, path])
                guard existing != nil else { try scanTree(path); return }
                try db.execute(sql: "UPDATE nodes SET seen=0 WHERE root=? AND path=?", arguments: [normalized, path])
                try db.execute(sql: "UPDATE nodes INDEXED BY node_children SET seen=0 WHERE root=? AND parent=?", arguments: [normalized, path])
                var newDirectories: [Data] = []
                let summary: ScanSummary
                do {
                    summary = try DirectoryScanner.enumerateDirectory(path: path, options: options, isCancelled: isCancelled) { batch in
                        for entry: ScanEntry in batch where entry.metadata.kind == .directory && entry.path != path {
                            let previous: Data? = try Data.fetchOne(db, sql: "SELECT metadata FROM nodes WHERE root=? AND path=?", arguments: [normalized, entry.path])
                            if let previous {
                                let metadata: FileMetadata = try decodeMetadata(previous)
                                if metadata.kind != .directory || metadata.device != entry.metadata.device || metadata.inode != entry.metadata.inode { newDirectories.append(entry.path) }
                            } else { newDirectories.append(entry.path) }
                        }
                        try apply(batch)
                    }
                } catch ScanError.systemCall(_, _, let code) where (code == ENOENT || code == ENOTDIR) && path != Data(normalized.utf8) {
                    try scanDirectory(parentPath(path))
                    return
                } catch ScanError.systemCall(let failedPath, let operation, let code) where (code == EACCES || code == EPERM) && path != Data(normalized.utf8) {
                    let issue: ScanIssue = ScanIssue(kind: .permissionDenied, path: failedPath, operation: operation, errnoCode: code)
                    issues.removeAll { $0.path == failedPath }
                    issues.append(issue)
                    try preserveUnreachable(db: db, root: normalized, issues: [issue], revision: revision)
                    return
                }
                metrics = addMetrics(metrics, summary.metrics)
                issues.removeAll { issue in
                    issue.path == path || (parentPath(issue.path) == path && [.metadataUnavailable, .vanished].contains(issue.kind))
                }
                issues += summary.issues
                try preserveUnreachable(db: db, root: normalized, issues: summary.issues, revision: revision)
                let stale: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM nodes INDEXED BY node_children WHERE root=? AND parent=? AND seen<>?", arguments: [normalized, path, revision])
                for obsolete: Data in stale {
                    try removeTree(db: db, root: normalized, path: obsolete, revision: revision)
                    issues.removeAll { $0.path == obsolete || isDescendant($0.path, of: obsolete) }
                }
                for child: Data in newDirectories { try scanTree(child) }
                try markAncestors(db: db, path: path, rootPath: Data(normalized.utf8))
            }
            func reconcile(_ update: JournalReplay) throws {
                let recursive: [Data] = minimalPaths(try update.recursiveDirectories.map { try resolveAliasPath(db: db, root: normalized, path: Data($0.utf8)) }.filter { path in !exclusions.contains(where: { excludedPath(path, directory: $0) }) })
                for path: Data in recursive {
                    if isCancelled() { throw ScanError.cancelled }
                    var metadata: stat = stat()
                    let exists: Int32 = path.withUnsafeBytes { bytes in
                        var terminated: [UInt8] = Array(bytes)
                        terminated.append(0)
                        return terminated.withUnsafeBytes { lstat($0.baseAddress!.assumingMemoryBound(to: CChar.self), &metadata) }
                    }
                    if exists != 0 && errno == ENOENT {
                        try removeTree(db: db, root: normalized, path: path, revision: revision)
                        issues.removeAll { $0.path == path || isDescendant($0.path, of: path) }
                        try markAncestors(db: db, path: path, rootPath: Data(normalized.utf8))
                    } else if exists == 0 && metadata.st_mode & S_IFMT == S_IFDIR {
                        try scanTree(path)
                    } else {
                        let parent: Data = parentPath(path)
                        try scanDirectory(parent)
                    }
                }
                for directory: String in update.dirtyDirectories {
                    let path: Data = try resolveAliasPath(db: db, root: normalized, path: Data(directory.utf8))
                    if !recursive.contains(where: { path == $0 || isDescendant(path, of: $0) }) { try scanDirectory(path) }
                }
            }
            if mode == .full || cached == nil || replay.requiresFullScan || rootChanged {
                try scanTree(Data(normalized.utf8))
            } else {
                issues = cached?.issues ?? []
                try reconcile(replay)
                if case .directories(let directories) = mode {
                    for directory: Data in minimalPaths(directories) {
                        let path: Data = try resolveAliasPath(db: db, root: normalized, path: directory)
                        try scanDirectory(path)
                    }
                }
                let retryPaths: [Data] = minimalPaths(issues.filter { [.metadataUnavailable, .ioError, .changedDuringScan, .vanished].contains($0.kind) }.map(\.path))
                for path: Data in retryPaths {
                    if try Bool.fetchOne(db, sql: "SELECT directory FROM nodes WHERE root=? AND path=?", arguments: [normalized, path]) == true {
                        try scanTree(path)
                    } else {
                        try scanDirectory(parentPath(path))
                    }
                }
            }
            var settled: Bool = false
            for _: Int in 0..<8 {
                let pending: JournalReplay = try journal.drain()
                currentCheckpoint = pending.checkpoint
                if pending.requiresFullScan {
                    try scanTree(Data(normalized.utf8))
                } else if pending.dirtyDirectories.isEmpty && pending.recursiveDirectories.isEmpty {
                    settled = true
                    break
                } else {
                    try reconcile(pending)
                }
            }
            guard settled else { throw IndexError.unstableFilesystem(normalized) }
            if isCancelled() { throw ScanError.cancelled }
            try rebuildAggregates(db: db, root: normalized)
            guard let row: Row = try Row.fetchOne(db, sql: "SELECT total_logical,total_allocated,total_count FROM nodes WHERE root=? AND path=?", arguments: [normalized, Data(normalized.utf8)]) else { throw IndexError.malformedCache("Root node missing after scan") }
            let blockingIssues: [ScanIssue] = issues.filter { $0.kind != .excluded && $0.kind != .directoryAlias && $0.kind != .mountBoundary }
            let summary: IndexSummary = IndexSummary(root: normalized, logicalBytes: UInt64(row["total_logical"] as Int64), allocatedBytes: UInt64(row["total_allocated"] as Int64), nodeCount: row["total_count"], revision: revision, lastScanDate: Date(), isComplete: blockingIssues.isEmpty, issues: issues, metrics: metrics)
            try db.execute(sql: "INSERT INTO roots(root,revision,summary,checkpoint) VALUES(?,?,?,?) ON CONFLICT(root) DO UPDATE SET revision=excluded.revision,summary=excluded.summary,checkpoint=excluded.checkpoint", arguments: [normalized, revision, try JSONEncoder().encode(summary), try currentCheckpoint.map { try JSONEncoder().encode($0) }])
            return summary
        }
        receiveEvent(.completed(result))
        return result
    }
}

private func normalizedRoot(_ root: String) -> String {
    URL(fileURLWithPath: root).standardizedFileURL.path
}

private func physicalDirectoryPath(_ path: String) throws -> String {
    let descriptor: Int32 = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw ScanError.systemCall(path: Data(path.utf8), operation: "open cache directory", errnoCode: errno) }
    defer { close(descriptor) }
    var bytes: [CChar] = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let code: Int32 = bytes.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH_NOFIRMLINK, $0.baseAddress!) }
    guard code == 0 else { throw ScanError.systemCall(path: Data(path.utf8), operation: "F_GETPATH_NOFIRMLINK cache directory", errnoCode: errno) }
    guard let physical: String = bytes.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) else { throw IndexError.invalidQuery("Cache directory path is not UTF-8") }
    return physical
}

private func loadSummary(db: Database, root: String) throws -> IndexSummary? {
    guard let data: Data = try Data.fetchOne(db, sql: "SELECT summary FROM roots WHERE root=?", arguments: [root]) else { return nil }
    return try JSONDecoder().decode(IndexSummary.self, from: data)
}

private func decodeNode(_ row: Row) throws -> IndexedNode {
    try indexedNode(RowData(path: row["path"], parent: row["parent"], name: row["name"], metadata: row["metadata"], logical: row["total_logical"], allocated: row["total_allocated"], count: row["total_count"], aliasTarget: row["alias_target"]))
}

private func pathDepth(_ path: Data) -> Int { path.reduce(0) { $0 + ($1 == 47 ? 1 : 0) } }

private func parentPath(_ path: Data) -> Data {
    guard let slash: Data.Index = path.lastIndex(of: 47), slash > path.startIndex else { return Data("/".utf8) }
    return Data(path[..<slash])
}

private func prefixRange(_ path: Data) -> (Data, Data) {
    var prefix: Data = path
    if prefix.last != 47 { prefix.append(47) }
    var upper: Data = prefix
    upper[upper.count - 1] = 48
    return (prefix, upper)
}

private func isDescendant(_ path: Data, of ancestor: Data) -> Bool {
    let prefix: Data = prefixRange(ancestor).0
    return path.starts(with: prefix)
}

private func excludedPath(_ path: Data, directory: Data) -> Bool {
    path == directory || isDescendant(path, of: directory)
}

private func minimalPaths(_ paths: [Data]) -> [Data] {
    var result: [Data] = []
    for path: Data in paths.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
        if !result.contains(where: { path == $0 || isDescendant(path, of: $0) }) { result.append(path) }
    }
    return result
}

private func removeTree(db: Database, root: String, path: Data, revision: Int64) throws {
    let (lower, upper): (Data, Data) = prefixRange(path)
    try db.execute(sql: "UPDATE nodes SET modified_revision=? WHERE root=? AND path=?", arguments: [revision, root, parentPath(path)])
    try db.execute(sql: "DELETE FROM nodes WHERE root=? AND path=?", arguments: [root, path])
    try db.execute(sql: "DELETE FROM nodes WHERE root=? AND path>=? AND path<?", arguments: [root, lower, upper])
    try db.execute(sql: "DELETE FROM aliases WHERE root=? AND (path=? OR (path>=? AND path<?) OR target=? OR (target>=? AND target<?))", arguments: [root, path, lower, upper, path, lower, upper])
}

private func removeUnseen(db: Database, root: String, path: Data, revision: Int64) throws {
    let (lower, upper): (Data, Data) = prefixRange(path)
    try db.execute(sql: "DELETE FROM nodes WHERE root=? AND seen<>? AND path=?", arguments: [root, revision, path])
    try db.execute(sql: "DELETE FROM nodes WHERE root=? AND seen<>? AND path>=? AND path<?", arguments: [root, revision, lower, upper])
    try db.execute(sql: "DELETE FROM aliases WHERE root=? AND seen<>? AND (path=? OR (path>=? AND path<?))", arguments: [root, revision, path, lower, upper])
}

private func preserveUnreachable(db: Database, root: String, issues: [ScanIssue], revision: Int64) throws {
    for issue: ScanIssue in issues where [.permissionDenied, .metadataUnavailable, .ioError, .changedDuringScan].contains(issue.kind) {
        let (lower, upper): (Data, Data) = prefixRange(issue.path)
        try db.execute(sql: "UPDATE nodes SET seen=? WHERE root=? AND path=?", arguments: [revision, root, issue.path])
        try db.execute(sql: "UPDATE nodes SET seen=? WHERE root=? AND path>=? AND path<?", arguments: [revision, root, lower, upper])
        try db.execute(sql: "UPDATE aliases SET seen=? WHERE root=? AND (path=? OR (path>=? AND path<?))", arguments: [revision, root, issue.path, lower, upper])
    }
}

private func resetSeen(db: Database, root: String, path: Data) throws {
    let (lower, upper): (Data, Data) = prefixRange(path)
    try db.execute(sql: "UPDATE nodes SET seen=0 WHERE root=? AND path=?", arguments: [root, path])
    try db.execute(sql: "UPDATE nodes SET seen=0 WHERE root=? AND path>=? AND path<?", arguments: [root, lower, upper])
    try db.execute(sql: "UPDATE aliases SET seen=0 WHERE root=? AND (path=? OR (path>=? AND path<?))", arguments: [root, path, lower, upper])
}

private func resolveAliasPath(db: Database, root: String, path: Data) throws -> Data {
    var current: Data = path
    var visited: Set<Data> = []
    while visited.insert(current).inserted {
        var ancestor: Data = current
        var replacement: Data?
        while ancestor == Data(root.utf8) || isDescendant(ancestor, of: Data(root.utf8)) {
            if let target: Data = try Data.fetchOne(db, sql: "SELECT target FROM aliases WHERE root=? AND path=?", arguments: [root, ancestor]) {
                replacement = target + current.dropFirst(ancestor.count)
                break
            }
            if ancestor == Data(root.utf8) { break }
            ancestor = parentPath(ancestor)
        }
        guard let replacement else { return current }
        current = replacement
    }
    throw IndexError.malformedCache("Filesystem alias cycle")
}

private func markRemovedParents(db: Database, root: String, path: Data, revision: Int64) throws {
    let (lower, upper): (Data, Data) = prefixRange(path)
    try db.execute(sql: "UPDATE nodes SET modified_revision=? WHERE root=? AND path IN (SELECT parent FROM nodes WHERE root=? AND seen<>? AND path=? UNION SELECT parent FROM nodes WHERE root=? AND seen<>? AND path>=? AND path<?)", arguments: [revision, root, root, revision, path, root, revision, lower, upper])
}

private func markAncestors(db: Database, path: Data, rootPath: Data) throws {
    var current: Data = path
    while current == rootPath || isDescendant(current, of: rootPath) {
        try db.execute(sql: "INSERT OR IGNORE INTO dirty(path,depth) VALUES(?,?)", arguments: [current, pathDepth(current)])
        if current == rootPath { break }
        current = parentPath(current)
    }
}

private func rebuildAggregates(db: Database, root: String) throws {
    let cursor: RowCursor = try Row.fetchCursor(db, sql: "SELECT path FROM dirty ORDER BY depth DESC")
    let update: Statement = try db.makeStatement(sql: """
        UPDATE nodes SET
            total_logical=logical+COALESCE((SELECT SUM(total_logical) FROM nodes c INDEXED BY node_children WHERE c.root=? AND c.parent=nodes.path),0),
            total_allocated=allocated+COALESCE((SELECT SUM(total_allocated) FROM nodes c INDEXED BY node_children WHERE c.root=? AND c.parent=nodes.path),0),
            total_count=1+COALESCE((SELECT SUM(total_count) FROM nodes c INDEXED BY node_children WHERE c.root=? AND c.parent=nodes.path),0),
            total_revision=MAX(modified_revision,COALESCE((SELECT MAX(total_revision) FROM nodes c INDEXED BY node_children WHERE c.root=? AND c.parent=nodes.path),0))
        WHERE root=? AND path=? AND directory=1
        """)
    while let row: Row = try cursor.next() {
        let path: Data = row["path"]
        try update.execute(arguments: [root, root, root, root, root, path])
    }
}

private func addMetrics(_ left: ScanMetrics, _ right: ScanMetrics) -> ScanMetrics {
    ScanMetrics(entries: left.entries + right.entries, directories: left.directories + right.directories, bulkCalls: left.bulkCalls + right.bulkCalls, metadataCalls: left.metadataCalls + right.metadataCalls, contentBytesRead: left.contentBytesRead + right.contentBytesRead)
}

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let components: (seconds: Int64, attoseconds: Int64) = start.duration(to: .now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
