import Darwin
import Dispatch
import Foundation
import GRDB
import Synchronization

public actor DiskIndex {
    private let pool: DatabasePool
    private let cacheDirectories: [Data]
    private let writerLockURL: URL

    public nonisolated static func open(databaseURL: URL) async throws -> DiskIndex {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DiskIndex, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try DiskIndex(databaseURL: databaseURL) })
            }
        }
    }

    public init(databaseURL: URL) throws {
        let directory: URL = databaseURL.deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory: String = directory.resolvingSymlinksInPath().path
        cacheDirectories = [Data(directory.path.utf8), Data(resolvedDirectory.utf8), Data(try physicalDirectoryPath(resolvedDirectory).utf8)]
        let resolvedDatabase: URL = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        let pending: URL = resolvedDatabase.appendingPathExtension("scan")
        let lockDirectory: String = try physicalDirectoryPath(resolvedDatabase.deletingLastPathComponent().path)
        writerLockURL = URL(fileURLWithPath: lockDirectory, isDirectory: true).appendingPathComponent(resolvedDatabase.lastPathComponent + ".write-lock", isDirectory: false)
        var configuration: Configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous=FULL")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            db.add(collation: DatabaseCollation("finder_name") { $0.localizedStandardCompare($1) })
            db.add(function: DatabaseFunction("file_last_opened", argumentCount: 1, pure: false) { values in
                guard let path: Data = Data.fromDatabaseValue(values[0]) else { throw IndexError.invalidQuery("Date last opened requires raw path bytes") }
                return try fileLastOpenedDate(path: path)?.timeIntervalSince1970
            })
        }
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        let version: Int32 = try pool.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
        guard (0...cacheSchemaVersion).contains(version) else { throw IndexError.incompatibleSchema(version) }
        if version != cacheSchemaVersion {
            let opened: DatabasePool = pool
            try bootstrapCacheWithWriterLock(at: writerLockURL, isReady: {
                let current: Int32 = try opened.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
                guard (0...cacheSchemaVersion).contains(current) else { throw IndexError.incompatibleSchema(current) }
                return current == cacheSchemaVersion
            }, bootstrap: {
                try opened.write { db in
                    let current: Int32 = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                    guard current != cacheSchemaVersion else { return }
                    try migrateFilesystemCache(db, pendingURL: pending)
                }
            })
        }
    }

    public nonisolated func cachedProgress(root: String) async throws -> IndexProgress? {
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in try cacheProgress(db, root: normalized, elapsed: 0) }
    }

    private nonisolated func repositoryRevision(path: String) async throws -> Int64? {
        try await pool.read { db in try Int64.fetchOne(db, sql: "SELECT total_revision FROM nodes WHERE path=?", arguments: [Data(path.utf8)]) }
    }

    public nonisolated func cachedSummary(root: String) async throws -> IndexSummary? {
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in try cacheSummary(db, root: normalized) }
    }

    public nonisolated func node(root: String, path: Data) async throws -> IndexedNode? {
        let normalized: String = normalizedRoot(root)
        guard cacheContains(path, in: Data(normalized.utf8)) else { return nil }
        return try await pool.read { db in
            guard let node: IndexedNode = try cacheNode(db, path: path) else { return nil }
            return try projectCacheNode(db, node: node, viewRoot: Data(normalized.utf8))
        }
    }

    public nonisolated func children(root: String, directory: Data, offset: Int, limit: Int) async throws -> [IndexedNode] {
        try await children(root: root, directory: directory, offset: offset, limit: limit, sort: NodeSort(column: .allocatedSize, order: .reverse))
    }

    public nonisolated func children(root: String, directory: Data, offset: Int, limit: Int, sort: NodeSort) async throws -> [IndexedNode] {
        guard offset >= 0, limit > 0, limit <= 10_000 else { throw IndexError.invalidQuery("offset must be >= 0 and limit must be 1 through 10000") }
        let normalized: String = normalizedRoot(root)
        guard cacheContains(directory, in: Data(normalized.utf8)) else { throw IndexError.invalidQuery("Directory is outside the selected folder: \(normalized)") }
        let direction: String = sort.order == .forward ? "ASC" : "DESC"
        let names: String = "CAST(name AS TEXT) COLLATE finder_name, name, path"
        let ordering: String
        let opened: String
        switch sort.column {
        case .name:
            ordering = "CAST(name AS TEXT) COLLATE finder_name \(direction), name \(direction), path \(direction)"
            opened = "NULL"
        case .allocatedSize, .sizeProportion:
            ordering = "total_allocated \(direction), \(names)"
            opened = "NULL"
        case .items:
            ordering = "CASE WHEN directory=1 THEN MAX(0,total_count-1) ELSE 1 END \(direction), \(names)"
            opened = "NULL"
        case .lastOpened:
            ordering = "last_opened IS NULL, last_opened \(direction), \(names)"
            opened = "file_last_opened(path)"
        }
        return try await pool.read { db in
            let resolved: Data = try resolveCacheAlias(db, path: directory)
            let hasAliases: Bool = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM aliases)")!
            return try Row.fetchAll(db, sql: "SELECT *, \(opened) AS last_opened, (SELECT target FROM aliases a WHERE a.path=nodes.path) AS alias_target FROM nodes INDEXED BY node_children WHERE parent=? ORDER BY \(ordering) LIMIT ? OFFSET ?", arguments: [resolved, limit, offset]).map { row in
                let decoded: IndexedNode = try decodeCacheNode(row)
                let node: IndexedNode = hasAliases ? try projectCacheNode(db, node: decoded, viewRoot: Data(normalized.utf8)) : decoded
                let timestamp: Double? = row["last_opened"]
                return IndexedNode(entry: node.entry, subtreeLogicalBytes: node.subtreeLogicalBytes, subtreeAllocatedBytes: node.subtreeAllocatedBytes, subtreeNodeCount: node.subtreeNodeCount, aliasTargetPath: node.aliasTargetPath, lastOpenedDate: timestamp.map { Date(timeIntervalSince1970: $0) })
            }
        }
    }

    public nonisolated func gitCandidates(root: String, offset: Int, limit: Int) async throws -> [String] {
        guard offset >= 0, limit > 0, limit <= 10_000 else { throw IndexError.invalidQuery("Invalid Git candidate page") }
        let normalized: String = normalizedRoot(root)
        return try await pool.read { db in
            let (lower, upper): (Data, Data) = cacheRange(Data(normalized.utf8))
            let paths: [Data] = try Data.fetchAll(db, sql: "SELECT parent FROM nodes WHERE name=? AND path>=? AND path<? ORDER BY path LIMIT ? OFFSET ?", arguments: [Data(".git".utf8), lower, upper, limit, offset])
            return try paths.map { path in
                guard let value: String = String(data: path, encoding: .utf8) else { throw IndexError.invalidQuery("Git requires a UTF-8 repository path") }
                return value
            }
        }
    }

    public func gitInfo(root: String, path: String, inspector: GitInspector) async throws -> CachedGitInfo? {
        let normalized: String = normalizedRoot(root)
        guard try await cachedSummary(root: normalized) != nil else { throw IndexError.invalidQuery("Scan this root before Git enrichment") }
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
            guard let revision: Int64 = try Int64.fetchOne(db, sql: "SELECT total_revision FROM nodes WHERE path=?", arguments: [Data(repositoryPath.utf8)]) else { throw IndexError.invalidQuery("Repository is absent from the cached tree: \(repositoryPath)") }
            return revision
        }
        let cached: GitRepositoryInfo? = try await pool.read { db in
            guard let row: Row = try Row.fetchOne(db, sql: "SELECT revision,fingerprint,info FROM git_cache WHERE path=?", arguments: [repositoryPath]), row["revision"] as Int64 == snapshotRevision else { return nil }
            let saved: GitInputFingerprint = try JSONDecoder().decode(GitInputFingerprint.self, from: row["fingerprint"])
            guard saved == fingerprint else { return nil }
            return try JSONDecoder().decode(GitRepositoryInfo.self, from: row["info"])
        }
        if let cached {
            guard try await self.repositoryRevision(path: repositoryPath) == snapshotRevision else { throw IndexError.staleEnrichment(repositoryPath) }
            return CachedGitInfo(info: cached, wasCached: true)
        }
        let enriched: (GitRepositoryInfo?, GitInputFingerprint?) = try await Task.detached(priority: .utility) {
            (try inspector.inspect(path: path), try inspector.fingerprint(path: path))
        }.value
        guard let info: GitRepositoryInfo = enriched.0 else { return nil }
        guard enriched.1 == fingerprint, try await self.repositoryRevision(path: repositoryPath) == snapshotRevision else { throw IndexError.staleEnrichment(repositoryPath) }
        try await withCacheWriterLock(at: writerLockURL, isCancelled: { Task.isCancelled }, onWait: {}) {
            try await self.pool.write { db in
                let currentRevision: Int64? = try Int64.fetchOne(db, sql: "SELECT total_revision FROM nodes WHERE path=?", arguments: [Data(repositoryPath.utf8)])
                guard currentRevision == snapshotRevision else { throw IndexError.staleEnrichment(repositoryPath) }
                try db.execute(sql: "INSERT INTO git_cache(path,revision,fingerprint,info) VALUES(?,?,?,?) ON CONFLICT(path) DO UPDATE SET revision=excluded.revision,fingerprint=excluded.fingerprint,info=excluded.info", arguments: [repositoryPath, snapshotRevision, try JSONEncoder().encode(fingerprint), try JSONEncoder().encode(info)])
            }
        }
        return CachedGitInfo(info: info, wasCached: false)
    }

    public func refresh(root: String, mode: RefreshMode, receiveEvent: @escaping @Sendable (IndexEvent) -> Void, isCancelled: @escaping @Sendable () -> Bool) async throws -> IndexSummary {
        let normalized: String = normalizedRoot(root)
        let requested: Data = Data(normalized.utf8)
        if case .directories(let directories) = mode {
            guard directories.allSatisfy({ cacheContains($0, in: requested) }) else { throw IndexError.invalidQuery("Changed directories must be inside the selected folder: \(normalized)") }
        }
        let cached: IndexSummary? = try await cachedSummary(root: normalized)
        receiveEvent(.started(cached: cached))
        if isCancelled() { throw ScanError.cancelled }
        return try await withCacheWriterLock(at: writerLockURL, isCancelled: isCancelled, onWait: { receiveEvent(.waitingForWriter) }) {
            receiveEvent(.writerAcquired)
            return try await self.scan(root: normalized, mode: mode, receiveEvent: receiveEvent, isCancelled: isCancelled)
        }
    }

    private func scan(root: String, mode: RefreshMode, receiveEvent: @escaping @Sendable (IndexEvent) -> Void, isCancelled: @escaping @Sendable () -> Bool) async throws -> IndexSummary {
        let start: ContinuousClock.Instant = .now
        let checkpoint: JournalCheckpoint? = try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM cache_state WHERE id=1").map { try JSONDecoder().decode(JournalCheckpoint.self, from: $0) }
        }
        let journal: FileEventJournal = try FileEventJournal(rootPath: "/", checkpoint: checkpoint, latency: 0.05)
        defer { journal.stop() }
        let replay: JournalReplay = try journal.replay(timeout: 10, isCancelled: isCancelled)
        let rootPath: Data = Data(root.utf8)
        var ancestors: [ScanEntry] = []
        var current: Data? = rootPath
        while let path: Data = current {
            let metadata: FileMetadata
            do { metadata = try DirectoryScanner.directoryMetadata(path: path) }
            catch ScanError.systemCall(_, _, let code) where path != rootPath && code == ENOTDIR {
                var native: stat = stat()
                let result: Int32 = (path + Data([0])).withUnsafeBytes { lstat($0.baseAddress!.assumingMemoryBound(to: CChar.self), &native) }
                guard result == 0 else { throw ScanError.systemCall(path: path, operation: "lstat ancestor", errnoCode: errno) }
                guard native.st_mode & S_IFMT == S_IFLNK else { throw ScanError.systemCall(path: path, operation: "open ancestor", errnoCode: code) }
                break
            }
            ancestors.append(ScanEntry(path: path, parentPath: cacheParent(path), name: path == Data("/".utf8) ? path : Data(path.suffix(from: path.lastIndex(of: 47)!.advanced(by: 1))), metadata: metadata))
            current = cacheParent(path)
        }
        let physicalRoots: Set<Data> = try directoryLocations(path: rootPath)
        let entries: [ScanEntry] = ancestors
        try await pool.write { db in
            let revision: Int64 = try beginCacheChanges(db)
            for entry: ScanEntry in entries.reversed() {
                let exists: Bool = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM nodes WHERE path=?)", arguments: [entry.path])!
                if entry.path == rootPath || !exists {
                    try recordCacheEntries(db, entries: [entry], directory: nil, epoch: 0, revision: revision)
                }
            }
            try storeDirectoryLocations(db, path: rootPath, locations: physicalRoots)
            try applyCacheReplay(db, replay: replay)
            switch mode {
            case .full: try invalidateCacheSubtree(db, path: rootPath)
            case .directories(let paths):
                for path: Data in paths { try invalidateCacheListing(db, path: path) }
            case .automatic: break
            }
            let resolved: Data = try resolveCacheAlias(db, path: rootPath)
            let scopes: [Data] = try cacheProjection(db, path: resolved, viewRoot: resolved)?.scopes ?? [resolved]
            for scope: Data in scopes {
                let (lower, upper): (Data, Data) = cacheRange(scope)
                let retries: [Data] = try Data.fetchAll(db, sql: """
                    SELECT path FROM directories WHERE done=1 AND report IS NOT NULL AND (path=? OR (path>=? AND path<?)) AND EXISTS(
                        SELECT 1 FROM json_each(CAST(report AS TEXT),'$.issues') WHERE json_extract(value,'$.kind') IN
                        ('permissionDenied','vanished','metadataUnavailable','ioError','changedDuringScan'))
                    """, arguments: [scope, lower, upper])
                for path: Data in retries { try invalidateCacheListing(db, path: path) }
            }
            try rebuildCacheTotals(db)
        }
        let options: ScanOptions = ScanOptions(batchSize: 512, bufferSize: 256 * 1024, mountPolicy: .crossDevices, excludedPaths: cacheDirectories)
        var metrics: ScanMetrics = emptyScanMetrics
        let highWater: Mutex<Double> = Mutex(0)
        let pool: DatabasePool = pool
        let publishProgress: @Sendable () throws -> Void = {
            if let value: IndexProgress = try pool.read({ db in try cacheProgress(db, root: root, elapsed: elapsedSeconds(start)) }) {
                let fraction: Double = highWater.withLock { previous in
                    previous = max(previous, value.completionFraction)
                    return previous
                }
                receiveEvent(.progress(IndexProgress(entriesObserved: value.entriesObserved, logicalBytesObserved: value.logicalBytesObserved,
                    allocatedBytesObserved: value.allocatedBytesObserved, elapsedSeconds: value.elapsedSeconds,
                    previousNodeCount: value.previousNodeCount, completionFraction: fraction)))
            }
        }
        try publishProgress()
        var settled: Bool = false
        for _: Int in 0..<8 {
            while let path: Data = try await pool.read({ db in
                try pendingCacheDirectory(db, root: rootPath)
            }) {
                if isCancelled() { throw ScanError.cancelled }
                let report: ScanSummary = try await enumerate(path: path, options: options, receiveEvent: receiveEvent, publishProgress: publishProgress, isCancelled: isCancelled)
                metrics = addMetrics(metrics, report.metrics)
                try publishProgress()
            }
            if isCancelled() { throw ScanError.cancelled }
            let pending: JournalReplay = try journal.drain()
            let invalidated: Bool = try await pool.write { db in
                _ = try beginCacheChanges(db)
                try applyCacheReplay(db, replay: pending)
                let resolved: Data = try resolveCacheAlias(db, path: rootPath)
                let scopes: [Data] = try cacheProjection(db, path: resolved, viewRoot: resolved)?.scopes ?? [resolved]
                for scope: Data in scopes {
                    let (lower, upper): (Data, Data) = cacheRange(scope)
                    let changed: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM directories WHERE done=1 AND report IS NOT NULL AND (path=? OR (path>=? AND path<?)) AND EXISTS(SELECT 1 FROM json_each(CAST(report AS TEXT),'$.issues') WHERE json_extract(value,'$.kind')='changedDuringScan')", arguments: [scope, lower, upper])
                    for directory: Data in changed { try invalidateCacheListing(db, path: directory) }
                }
                try rebuildCacheTotals(db)
                return try pendingCacheDirectory(db, root: rootPath) != nil
            }
            if !invalidated { settled = true; break }
        }
        guard settled else { throw IndexError.unstableFilesystem(root) }
        if isCancelled() { throw ScanError.cancelled }
        let completedMetrics: ScanMetrics = metrics
        let result: IndexSummary = try await pool.write { db in
            let completedRevision: Int64 = try beginCacheChanges(db)
            let resolved: Data = try resolveCacheAlias(db, path: rootPath)
            try db.execute(sql: "UPDATE nodes SET scan_revision=?,scan_date=?,scan_metrics=? WHERE path=?", arguments: [completedRevision, Date().timeIntervalSince1970, try JSONEncoder().encode(completedMetrics), resolved])
            try markCacheAncestors(db, path: resolved)
            try rebuildCacheTotals(db)
            guard let summary: IndexSummary = try cacheSummary(db, root: root) else { throw IndexError.malformedCache("Selected folder missing after scan: \(root)") }
            return summary
        }
        receiveEvent(.progress(IndexProgress(entriesObserved: result.nodeCount, logicalBytesObserved: result.logicalBytes, allocatedBytesObserved: result.allocatedBytes, elapsedSeconds: elapsedSeconds(start), previousNodeCount: result.nodeCount, completionFraction: 1)))
        receiveEvent(.completed(result))
        return result
    }

    private func enumerate(path: Data, options: ScanOptions, receiveEvent: @escaping @Sendable (IndexEvent) -> Void, publishProgress: @escaping @Sendable () throws -> Void, isCancelled: @escaping @Sendable () -> Bool) async throws -> ScanSummary {
        let epoch: Int64 = try await pool.write { db in
            try db.execute(sql: "UPDATE cache_state SET epoch=epoch+1 WHERE id=1")
            return try Int64.fetchOne(db, sql: "SELECT epoch FROM cache_state WHERE id=1")!
        }
        let opened: FileMetadata
        do { opened = try DirectoryScanner.directoryMetadata(path: path) }
        catch ScanError.systemCall(let failed, let operation, let code) {
            let kind: ScanIssueKind
            if code == EACCES || code == EPERM {
                kind = .permissionDenied
            } else if code == ENOENT || code == ENOTDIR {
                kind = .vanished
            } else {
                kind = .ioError
            }
            let report: ScanSummary = ScanSummary(metrics: emptyScanMetrics, issues: [ScanIssue(kind: kind, path: failed, operation: operation, errnoCode: code)], aliases: [])
            try await pool.write { db in
                let revision: Int64 = try beginCacheChanges(db)
                if code == ENOENT || code == ENOTDIR {
                    try removeCacheTree(db, path: path, revision: revision)
                    if let parent: Data = cacheParent(path) { try invalidateCacheListing(db, path: parent) }
                } else {
                    try db.execute(sql: "UPDATE directories SET done=1,observed=1,report=? WHERE path=?", arguments: [try JSONEncoder().encode(report), path])
                    try db.execute(sql: "UPDATE nodes SET scan_revision=(SELECT revision FROM cache_state WHERE id=1) WHERE path=?", arguments: [path])
                    try markCacheAncestors(db, path: path)
                }
                try rebuildCacheTotals(db)
            }
            return report
        }
        let alias: Data? = try await pool.read { db in
            if let existing: Data = try Data.fetchOne(db, sql: "SELECT target FROM aliases WHERE path=?", arguments: [path]),
               let target: IndexedNode = try cacheNode(db, path: try resolveCacheAlias(db, path: existing)),
               target.entry.metadata.device == opened.device, target.entry.metadata.inode == opened.inode,
               target.entry.metadata.birthTime == opened.birthTime { return existing }
            let ownsObservations: Bool = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM nodes n JOIN directories d ON d.path=n.path WHERE n.path=? AND (n.total_count>1 OR d.observed=1) AND NOT EXISTS(SELECT 1 FROM aliases a WHERE a.path=n.path))", arguments: [path])!
            if ownsObservations { return nil }
            let candidates: [Row] = try Row.fetchAll(db, sql: "SELECT n.path,n.metadata FROM nodes n JOIN directories d ON d.path=n.path WHERE (d.observed=1 OR n.total_count>1) AND n.path<>? AND n.directory=1 AND NOT EXISTS(SELECT 1 FROM aliases a WHERE a.path=n.path) AND substr(n.metadata,9,16)=? ORDER BY length(n.path),n.path", arguments: [path, encodeMetadata(opened).subdata(in: 8..<24)])
            for row: Row in candidates {
                let metadata: FileMetadata = try decodeMetadata(row["metadata"])
                if metadata.birthTime == opened.birthTime, !cacheContains(row["path"], in: path) { return row["path"] }
            }
            return nil
        }
        if let alias {
            let report: ScanSummary = ScanSummary(metrics: emptyScanMetrics, issues: [ScanIssue(kind: .directoryAlias, path: path, operation: "descend", errnoCode: 0)], aliases: [ScanAlias(aliasPath: path, targetPath: alias)])
            try await pool.write { db in
                let revision: Int64 = try beginCacheChanges(db)
                let children: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM nodes WHERE parent=?", arguments: [path])
                for child: Data in children { try removeCacheTree(db, path: child, revision: revision) }
                try db.execute(sql: "INSERT INTO aliases(path,target,seen) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET target=excluded.target,seen=excluded.seen", arguments: [path, alias, epoch])
                try db.execute(sql: "UPDATE directories SET done=1,observed=1,report=? WHERE path=?", arguments: [try JSONEncoder().encode(report), path])
                try db.execute(sql: "UPDATE nodes SET scan_revision=(SELECT revision FROM cache_state WHERE id=1) WHERE path=?", arguments: [path])
                try markCacheAncestors(db, path: path)
                try rebuildCacheTotals(db)
            }
            return report
        }
        let pool: DatabasePool = pool
        let report: ScanSummary = try await Task.detached(priority: .utility) {
            try DirectoryScanner.enumerateDirectory(path: path, options: options, isCancelled: isCancelled, receiveProgress: { _ in }) { batch in
                try pool.write { db in
                    let observedRevision: Int64 = try beginCacheChanges(db)
                    try recordCacheEntries(db, entries: batch, directory: path, epoch: epoch, revision: observedRevision)
                    try rebuildCacheTotals(db)
                }
                receiveEvent(.batch(batch))
                try publishProgress()
            }
        }.value
        try await pool.write { db in
            let revision: Int64 = try beginCacheChanges(db)
            let failed: Bool = report.issues.contains { ![.excluded, .mountBoundary, .directoryAlias].contains($0.kind) }
            if !failed {
                let obsolete: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM nodes INDEXED BY node_children WHERE parent=? AND seen<>?", arguments: [path, epoch])
                for child: Data in obsolete { try removeCacheTree(db, path: child, revision: revision) }
            }
            try db.execute(sql: "DELETE FROM aliases WHERE path=?", arguments: [path])
            try db.execute(sql: "UPDATE directories SET done=1,observed=1,report=? WHERE path=?", arguments: [try JSONEncoder().encode(report), path])
            try db.execute(sql: "UPDATE nodes SET scan_revision=(SELECT revision FROM cache_state WHERE id=1) WHERE path=?", arguments: [path])
            try markCacheAncestors(db, path: path)
            try rebuildCacheTotals(db)
        }
        return report
    }
}

private func normalizedRoot(_ root: String) -> String { URL(fileURLWithPath: root).standardizedFileURL.path }

private func physicalDirectoryPath(_ path: String) throws -> String {
    let descriptor: Int32 = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw ScanError.systemCall(path: Data(path.utf8), operation: "open cache directory", errnoCode: errno) }
    defer { _ = close(descriptor) }
    var bytes: [CChar] = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH_NOFIRMLINK, &bytes) == 0 else { throw ScanError.systemCall(path: Data(path.utf8), operation: "F_GETPATH_NOFIRMLINK cache directory", errnoCode: errno) }
    let result: String? = bytes.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    guard let result else { throw ScanError.invalidPath(Data(path.utf8)) }
    return result
}

private func applyCacheReplay(_ db: Database, replay: JournalReplay) throws {
    if replay.requiresFullScan {
        let paths: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM directories WHERE done=1")
        for path: Data in paths { try invalidateCacheListing(db, path: path) }
    } else {
        for path: String in replay.recursiveDirectories {
            let physical: Data = Data(path.utf8)
            let (lower, upper): (Data, Data) = cacheRange(physical)
            var paths: Set<Data> = try journalCachePaths(db, physical: physical)
            paths.formUnion(try Data.fetchAll(db, sql: "SELECT path FROM physical_paths WHERE physical>=? AND physical<?", arguments: [lower, upper]))
            for mapped: Data in paths { try invalidateCacheSubtree(db, path: mapped) }
        }
        for path: String in replay.dirtyDirectories {
            for mapped: Data in try journalCachePaths(db, physical: Data(path.utf8)) { try invalidateCacheListing(db, path: mapped) }
        }
    }
    try db.execute(sql: "UPDATE cache_state SET checkpoint=? WHERE id=1", arguments: [try replay.checkpoint.map { try JSONEncoder().encode($0) }])
}

private func addMetrics(_ left: ScanMetrics, _ right: ScanMetrics) -> ScanMetrics {
    ScanMetrics(entries: left.entries + right.entries, directories: left.directories + right.directories, bulkCalls: left.bulkCalls + right.bulkCalls, metadataCalls: left.metadataCalls + right.metadataCalls, contentBytesRead: left.contentBytesRead + right.contentBytesRead)
}

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let value: Duration = start.duration(to: .now)
    return Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
}

private func journalCachePaths(_ db: Database, physical: Data) throws -> Set<Data> {
    var paths: Set<Data> = [physical]
    var ancestor: Data? = physical
    while let current: Data = ancestor {
        let locations: [Data] = try Data.fetchAll(db, sql: "SELECT path FROM physical_paths WHERE physical=?", arguments: [current])
        for location: Data in locations { paths.insert(location + physical.dropFirst(current.count)) }
        ancestor = cacheParent(current)
    }
    return paths
}

private func directoryLocations(path: Data) throws -> Set<Data> {
    let descriptor: Int32 = (path + Data([0])).withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw ScanError.systemCall(path: path, operation: "open journal location", errnoCode: errno) }
    defer { _ = close(descriptor) }
    var locations: Set<Data> = []
    for command: Int32 in [F_GETPATH, F_GETPATH_NOFIRMLINK] {
        var bytes: [UInt8] = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, command, &bytes) == 0 else { throw ScanError.systemCall(path: path, operation: "fcntl journal location", errnoCode: errno) }
        locations.insert(Data(bytes.prefix { $0 != 0 }))
    }
    return locations
}

private func storeDirectoryLocations(_ db: Database, path: Data, locations: Set<Data>) throws {
    try db.execute(sql: "DELETE FROM physical_paths WHERE path=?", arguments: [path])
    for location: Data in locations { try db.execute(sql: "INSERT INTO physical_paths(path,physical) VALUES(?,?)", arguments: [path, location]) }
}
