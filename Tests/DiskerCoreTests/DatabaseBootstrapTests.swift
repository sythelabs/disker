import Darwin
import Dispatch
import Foundation
import GRDB
import Testing
@testable import DiskerCore

private struct DatabaseBootstrapFixture: Sendable {
    let container: URL
    let root: URL
    let database: URL
    let connection: DatabaseQueue
}

private func databaseBootstrapFixture() throws -> DatabaseBootstrapFixture {
    let container: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-database-bootstrap-" + UUID().uuidString).resolvingSymlinksInPath()
    let root: URL = container.appendingPathComponent("root", isDirectory: true)
    let directory: URL = container.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database: URL = directory.appendingPathComponent("index.sqlite")
    var configuration: Configuration = Configuration()
    configuration.journalMode = .wal
    let connection: DatabaseQueue = try DatabaseQueue(path: database.path, configuration: configuration)
    return DatabaseBootstrapFixture(container: container, root: root, database: database, connection: connection)
}

private func removeDatabaseBootstrapFixture(_ fixture: DatabaseBootstrapFixture) {
    do { try FileManager.default.removeItem(at: fixture.container) } catch { Issue.record(error) }
}

private func holdDatabaseBootstrapLock(_ database: URL) throws -> Int32 {
    let path: String = database.path + ".write-lock"
    let descriptor: Int32 = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CacheWriterLockError.systemCall(path: path, operation: "open", code: errno) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        let code: Int32 = errno
        guard close(descriptor) == 0 else { throw CacheWriterLockError.systemCall(path: path, operation: "close", code: errno) }
        throw CacheWriterLockError.systemCall(path: path, operation: "flock", code: code)
    }
    return descriptor
}

private func waitForBootstrapSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

private func openDatabaseBootstrapIndex(database: URL, started: DispatchSemaphore, finished: DispatchSemaphore) -> Task<DiskIndex, any Error> {
    Task.detached(priority: .utility) {
        defer { finished.signal() }
        started.signal()
        return try await DiskIndex.open(databaseURL: database)
    }
}


private func createLegacyCache(_ db: Database) throws {
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

private func legacyFileMetadata(_ file: URL) throws -> FileMetadata {
    var entries: [ScanEntry] = []
    _ = try DirectoryScanner.enumerateDirectory(path: Data(file.deletingLastPathComponent().path.utf8),
        options: ScanOptions(batchSize: 512, bufferSize: 262_144, mountPolicy: .crossDevices, excludedPaths: []),
        isCancelled: { false }, receiveProgress: { _ in }, receiveBatch: { entries.append(contentsOf: $0) })
    return try #require(entries.first { $0.path == Data(file.path.utf8) }).metadata
}

private func insertLegacyEntry(_ db: Database, root: String, entry: ScanEntry) throws {
    let directory: Bool = entry.metadata.kind == .directory
    let logical: Int64 = directory ? 0 : Int64(entry.metadata.logicalBytes)
    let allocated: Int64 = Int64(entry.metadata.allocatedBytes)
    try db.execute(sql: "INSERT INTO nodes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", arguments: [root, entry.path, entry.parentPath, entry.name, cacheDepth(entry.path), directory, encodeMetadata(entry.metadata), logical, allocated, logical, allocated, 1, 1, 1, 1])
}

@Suite("Database bootstrap", .serialized)
struct DatabaseBootstrapTests {
    @Test(arguments: [true, false], [true, false])
    func migrationMergesOverlappingCommittedAndInterruptedObservations(validPending: Bool, incomplete: Bool) async throws {
        let fixture: DatabaseBootstrapFixture = try databaseBootstrapFixture()
        defer { removeDatabaseBootstrapFixture(fixture) }
        let child: URL = fixture.root.appendingPathComponent("child")
        let file: URL = child.appendingPathComponent("file")
        let sibling: URL = fixture.root.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: file)
        let old: ScanEntry = ScanEntry(path: Data(file.path.utf8), parentPath: Data(child.path.utf8), name: Data("file".utf8), metadata: try legacyFileMetadata(file))
        let parentEntry: ScanEntry = ScanEntry(path: Data(fixture.root.path.utf8), parentPath: nil, name: Data("root".utf8), metadata: try DirectoryScanner.directoryMetadata(path: Data(fixture.root.path.utf8)))
        let childEntry: ScanEntry = ScanEntry(path: Data(child.path.utf8), parentPath: Data(fixture.root.path.utf8), name: Data("child".utf8), metadata: try DirectoryScanner.directoryMetadata(path: Data(child.path.utf8)))
        let issue: ScanIssue = ScanIssue(kind: .permissionDenied, path: childEntry.path, operation: "fixture", errnoCode: EACCES)
        let summary: IndexSummary = IndexSummary(root: fixture.root.path, logicalBytes: 3, allocatedBytes: old.metadata.allocatedBytes, nodeCount: 3, revision: 4, lastScanDate: Date(timeIntervalSince1970: 1_700_000_000), isComplete: !incomplete, issues: incomplete ? [issue] : [], metrics: emptyScanMetrics)
        try await fixture.connection.write { db in
            try createLegacyCache(db)
            try db.execute(sql: "INSERT INTO roots VALUES(?,?,?,NULL)", arguments: [fixture.root.path, 4, try JSONEncoder().encode(summary)])
            for entry: ScanEntry in [parentEntry, childEntry, old] { try insertLegacyEntry(db, root: fixture.root.path, entry: entry) }
        }
        try Data(repeating: 2, count: 17).write(to: file)
        try Data(repeating: 3, count: 5).write(to: sibling)
        let updated: ScanEntry = ScanEntry(path: old.path, parentPath: old.parentPath, name: old.name, metadata: try legacyFileMetadata(file))
        let added: ScanEntry = ScanEntry(path: Data(sibling.path.utf8), parentPath: parentEntry.path, name: Data("sibling".utf8), metadata: try legacyFileMetadata(sibling))
        let pending: DatabaseQueue = try DatabaseQueue(path: fixture.database.appendingPathExtension("scan").path)
        try await pending.write { db in
            try db.execute(sql: "CREATE TABLE scans(root TEXT PRIMARY KEY,identity BLOB NOT NULL,checkpoint BLOB); CREATE TABLE entries(id INTEGER PRIMARY KEY,root TEXT,path BLOB,parent BLOB,name BLOB,metadata BLOB)")
            for root: String in [fixture.root.path, child.path] {
                let base: Int = root == fixture.root.path ? (validPending ? 5 : 4) : (validPending ? 1 : 0)
                try db.execute(sql: "INSERT INTO scans VALUES(?,?,NULL)", arguments: [root, Data("{\"revision\":\(base)}".utf8)])
                for entry: ScanEntry in root == fixture.root.path ? [updated, added] : [updated] {
                    try db.execute(sql: "INSERT INTO entries(root,path,parent,name,metadata) VALUES(?,?,?,?,?)", arguments: [root, entry.path, entry.parentPath, entry.name, encodeMetadata(entry.metadata)])
                }
            }
        }
        let migrated: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        #expect(try await migrated.cachedSummary(root: fixture.root.path)?.logicalBytes == (validPending ? 22 : 3))
        #expect(try await migrated.cachedSummary(root: fixture.root.path)?.isComplete == false)
        #expect(try await migrated.cachedSummary(root: fixture.root.path)?.issues.contains { $0.kind == .permissionDenied } == incomplete)
        #expect(try await migrated.cachedSummary(root: fixture.root.path)?.lastScanDate == summary.lastScanDate)
        #expect(try await migrated.cachedSummary(root: child.path)?.logicalBytes == (validPending ? 17 : 3))
        #expect(try await migrated.cachedSummary(root: fixture.container.path) != nil)
        #expect(try await migrated.node(root: child.path, path: old.path)?.entry.metadata.logicalBytes == (validPending ? 17 : 3))
        let count: Int = try await fixture.connection.read { db in
            #expect(try db.tableExists("roots") == false)
            #expect(try db.tableExists("legacy_nodes") == false)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nodes WHERE path=?", arguments: [old.path])!
        }
        #expect(count == 1)
        let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        #expect(try await reopened.cachedSummary(root: fixture.root.path) == migrated.cachedSummary(root: fixture.root.path))
    }

    @Test func failedMigrationRollsBackWithoutChangingLegacyObservations() async throws {
        let fixture: DatabaseBootstrapFixture = try databaseBootstrapFixture()
        defer { removeDatabaseBootstrapFixture(fixture) }
        try await fixture.connection.write { db in try createLegacyCache(db) }
        let pending: DatabaseQueue = try DatabaseQueue(path: fixture.database.appendingPathExtension("scan").path)
        try await pending.write { db in try db.execute(sql: "CREATE TABLE unexpected(value INTEGER)") }
        #expect(throws: IndexError.self) { try DiskIndex(databaseURL: fixture.database) }
        try await fixture.connection.read { (db: Database) throws -> Void in
            #expect(try db.tableExists("roots"))
            #expect(try db.tableExists("legacy_roots") == false)
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
        }
    }

    @Test func bootstrapDoesNotWriteUntilExternalWriterReleasesLock() async throws {
        let fixture: DatabaseBootstrapFixture = try databaseBootstrapFixture()
        defer { removeDatabaseBootstrapFixture(fixture) }
        let descriptor: Int32 = try holdDatabaseBootstrapLock(fixture.database)
        defer {
            if close(descriptor) != 0 { Issue.record("Could not close bootstrap writer lock: \(errno)") }
        }
        let started: DispatchSemaphore = DispatchSemaphore(value: 0)
        let finished: DispatchSemaphore = DispatchSemaphore(value: 0)
        let opening: Task<DiskIndex, any Error> = openDatabaseBootstrapIndex(database: fixture.database, started: started, finished: finished)
        let attempted: DispatchTimeoutResult = await waitForBootstrapSignal(started, timeout: .now() + 2)
        #expect(attempted == .success)
        let completedWhileLocked: DispatchTimeoutResult = await waitForBootstrapSignal(finished, timeout: .now() + 0.2)
        #expect(completedWhileLocked == .timedOut)
        let versionWhileLocked: Int32? = try await fixture.connection.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") }
        #expect(versionWhileLocked == 0)
        guard flock(descriptor, LOCK_UN) == 0 else { throw CacheWriterLockError.systemCall(path: fixture.database.path + ".write-lock", operation: "flock", code: errno) }
        let index: DiskIndex = try await opening.value
        #expect(try await index.cachedSummary(root: fixture.root.path) == nil)
        let versionAfterBootstrap: Int32? = try await fixture.connection.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") }
        #expect(versionAfterBootstrap == 2)
    }

    @Test func waitingBootstrapReturnsWhenSchemaCommitsWithoutWaitingForWriterRelease() async throws {
        let fixture: DatabaseBootstrapFixture = try databaseBootstrapFixture()
        defer { removeDatabaseBootstrapFixture(fixture) }
        try Data(repeating: 1, count: 3).write(to: fixture.root.appendingPathComponent("file"))
        let original: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await original.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try await fixture.connection.write { db in try db.execute(sql: "PRAGMA user_version=0") }
        let descriptor: Int32 = try holdDatabaseBootstrapLock(fixture.database)
        defer {
            if close(descriptor) != 0 { Issue.record("Could not close bootstrap writer lock: \(errno)") }
        }
        let started: DispatchSemaphore = DispatchSemaphore(value: 0)
        let finished: DispatchSemaphore = DispatchSemaphore(value: 0)
        let opening: Task<DiskIndex, any Error> = openDatabaseBootstrapIndex(database: fixture.database, started: started, finished: finished)
        let attempted: DispatchTimeoutResult = await waitForBootstrapSignal(started, timeout: .now() + 2)
        #expect(attempted == .success)
        let completedBeforeSchemaCommit: DispatchTimeoutResult = await waitForBootstrapSignal(finished, timeout: .now() + 0.2)
        #expect(completedBeforeSchemaCommit == .timedOut)
        let writerEntered: DispatchSemaphore = DispatchSemaphore(value: 0)
        let writerRelease: DispatchSemaphore = DispatchSemaphore(value: 0)
        defer { writerRelease.signal() }
        let writer: Task<Void, any Error> = Task.detached(priority: .utility) {
            try await fixture.connection.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA user_version=2")
                try db.inTransaction(.immediate) {
                    writerEntered.signal()
                    if writerRelease.wait(timeout: .now() + 15) == .timedOut { Issue.record("Timed out waiting to release bootstrap SQLite writer") }
                    return .commit
                }
            }
        }
        let beganWriting: DispatchTimeoutResult = await waitForBootstrapSignal(writerEntered, timeout: .now() + 2)
        #expect(beganWriting == .success)
        let completedAfterSchemaCommit: DispatchTimeoutResult = await waitForBootstrapSignal(finished, timeout: .now() + 2)
        #expect(completedAfterSchemaCommit == .success)
        if completedAfterSchemaCommit == .success {
            let index: DiskIndex = try await opening.value
            #expect(try await index.cachedSummary(root: fixture.root.path) == previous)
        }
        guard flock(descriptor, LOCK_UN) == 0 else { throw CacheWriterLockError.systemCall(path: fixture.database.path + ".write-lock", operation: "flock", code: errno) }
        writerRelease.signal()
        try await writer.value
        _ = try await opening.value
    }
}
