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

@Suite("Database bootstrap", .serialized)
struct DatabaseBootstrapTests {
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
        #expect(versionAfterBootstrap == 1)
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
                try db.execute(sql: "PRAGMA user_version=1")
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
