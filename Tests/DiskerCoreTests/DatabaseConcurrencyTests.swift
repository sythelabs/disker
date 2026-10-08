import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import DiskerCore

private struct DatabaseConcurrencyFixture: Sendable {
    let container: URL
    let root: URL
    let database: URL
}

private func databaseConcurrencyFixture() throws -> DatabaseConcurrencyFixture {
    let container: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-database-concurrency-\(UUID().uuidString)").resolvingSymlinksInPath()
    let root: URL = container.appendingPathComponent("root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return DatabaseConcurrencyFixture(container: container, root: root, database: container.appendingPathComponent("cache/index.sqlite"))
}

private func removeDatabaseConcurrencyFixture(_ fixture: DatabaseConcurrencyFixture) {
    do { try FileManager.default.removeItem(at: fixture.container) } catch { Issue.record(error) }
}

private func waitForDatabaseSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

private func pausedDatabaseRefresh(index: DiskIndex, root: URL, entered: DispatchSemaphore, release: DispatchSemaphore) -> Task<IndexSummary, any Error> {
    let paused: Mutex<Bool> = Mutex(false)
    return Task.detached(priority: .utility) {
        try await index.refresh(root: root.path, mode: .full, receiveEvent: { event in
            guard case .batch = event else { return }
            let shouldPause: Bool = paused.withLock { state in
                if state { return false }
                state = true
                return true
            }
            if shouldPause {
                entered.signal()
                if release.wait(timeout: .now() + 15) == .timedOut { Issue.record("Timed out waiting to release database writer") }
            }
        }, isCancelled: { false })
    }
}

@Suite("Database concurrency", .serialized)
struct DatabaseConcurrencyTests {
    @Test func concurrentRefreshWaitsForWriterWithoutLosingCommittedSnapshot() async throws {
        let fixture: DatabaseConcurrencyFixture = try databaseConcurrencyFixture()
        defer { removeDatabaseConcurrencyFixture(fixture) }
        let root: URL = fixture.root
        let file: URL = root.appendingPathComponent("file")
        try Data(repeating: 1, count: 3).write(to: file)
        let first: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await first.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let second: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        try Data(repeating: 1, count: 9).write(to: file)
        let entered: DispatchSemaphore = DispatchSemaphore(value: 0)
        let release: DispatchSemaphore = DispatchSemaphore(value: 0)
        let secondStarted: DispatchSemaphore = DispatchSemaphore(value: 0)
        let secondFinished: DispatchSemaphore = DispatchSemaphore(value: 0)
        let queryFinished: DispatchSemaphore = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstRefresh: Task<IndexSummary, any Error> = pausedDatabaseRefresh(index: first, root: root, entered: entered, release: release)
        let firstStarted: DispatchTimeoutResult = await waitForDatabaseSignal(entered, timeout: .now() + 2)
        #expect(firstStarted == .success)
        let secondRefresh: Task<IndexSummary, any Error> = Task.detached(priority: .utility) {
            defer { secondFinished.signal() }
            return try await second.refresh(root: root.path, mode: .full, receiveEvent: { event in
                if case .started = event { secondStarted.signal() }
            }, isCancelled: { false })
        }
        let attempted: DispatchTimeoutResult = await waitForDatabaseSignal(secondStarted, timeout: .now() + 2)
        #expect(attempted == .success)
        let query: Task<([IndexedNode], IndexSummary?), any Error> = Task.detached(priority: .utility) {
            defer { queryFinished.signal() }
            let children: [IndexedNode] = try await second.children(root: root.path, directory: Data(root.path.utf8), offset: 0, limit: 10)
            let summary: IndexSummary? = try await second.cachedSummary(root: root.path)
            return (children, summary)
        }
        let queried: DispatchTimeoutResult = await waitForDatabaseSignal(queryFinished, timeout: .now() + 2)
        #expect(queried == .success)
        let completedBeforeRelease: DispatchTimeoutResult = await waitForDatabaseSignal(secondFinished, timeout: .now() + 6)
        #expect(completedBeforeRelease == .timedOut)
        release.signal()
        let firstSummary: IndexSummary = try await firstRefresh.value
        let (children, cached): ([IndexedNode], IndexSummary?) = try await query.value
        #expect(children.count == 1)
        #expect(children.first?.entry.metadata.logicalBytes == 9)
        #expect(cached!.revision > previous.revision)
        #expect(cached?.logicalBytes == 9)
        let secondSummary: IndexSummary = try await secondRefresh.value
        #expect(firstSummary.logicalBytes == 9)
        #expect(secondSummary.logicalBytes == 9)
        #expect(firstSummary.revision > previous.revision)
        #expect(secondSummary.revision > firstSummary.revision)
    }

    @Test func cancelledRefreshStopsWaitingWithoutCommitting() async throws {
        let fixture: DatabaseConcurrencyFixture = try databaseConcurrencyFixture()
        defer { removeDatabaseConcurrencyFixture(fixture) }
        let root: URL = fixture.root
        let file: URL = root.appendingPathComponent("file")
        try Data(repeating: 1, count: 3).write(to: file)
        let first: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await first.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let second: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        try Data(repeating: 1, count: 9).write(to: file)
        let entered: DispatchSemaphore = DispatchSemaphore(value: 0)
        let release: DispatchSemaphore = DispatchSemaphore(value: 0)
        let secondWaiting: DispatchSemaphore = DispatchSemaphore(value: 0)
        let secondFinished: DispatchSemaphore = DispatchSemaphore(value: 0)
        let cancelled: Mutex<Bool> = Mutex(false)
        defer { release.signal() }
        let firstRefresh: Task<IndexSummary, any Error> = pausedDatabaseRefresh(index: first, root: root, entered: entered, release: release)
        let firstStarted: DispatchTimeoutResult = await waitForDatabaseSignal(entered, timeout: .now() + 2)
        #expect(firstStarted == .success)
        let secondRefresh: Task<IndexSummary, any Error> = Task.detached(priority: .utility) {
            defer { secondFinished.signal() }
            return try await second.refresh(root: root.path, mode: .full, receiveEvent: { event in
                if case .waitingForWriter = event { secondWaiting.signal() }
            }, isCancelled: { cancelled.withLock { $0 } })
        }
        let attempted: DispatchTimeoutResult = await waitForDatabaseSignal(secondWaiting, timeout: .now() + 2)
        #expect(attempted == .success)
        cancelled.withLock { $0 = true }
        let cancellationCompleted: DispatchTimeoutResult = await waitForDatabaseSignal(secondFinished, timeout: .now() + 2)
        #expect(cancellationCompleted == .success)
        release.signal()
        let firstSummary: IndexSummary = try await firstRefresh.value
        await #expect(throws: ScanError.cancelled) { try await secondRefresh.value }
        let cached: IndexSummary? = try await second.cachedSummary(root: root.path)
        #expect(firstSummary.revision > previous.revision)
        #expect(cached?.revision == firstSummary.revision)
        #expect(cached?.logicalBytes == 9)
    }

    @Test func refreshHonorsAnIndependentFileDescriptorWriterLock() async throws {
        let fixture: DatabaseConcurrencyFixture = try databaseConcurrencyFixture()
        defer { removeDatabaseConcurrencyFixture(fixture) }
        let root: URL = fixture.root
        try Data(repeating: 1, count: 3).write(to: root.appendingPathComponent("file"))
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let lockPath: String = fixture.database.path + ".write-lock"
        let descriptor: Int32 = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ScanError.systemCall(path: Data(lockPath.utf8), operation: "open", errnoCode: errno) }
        defer {
            if close(descriptor) != 0 { Issue.record("Could not close fixture writer lock: \(errno)") }
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ScanError.systemCall(path: Data(lockPath.utf8), operation: "flock", errnoCode: errno) }
        defer {
            if flock(descriptor, LOCK_UN) != 0 { Issue.record("Could not release fixture writer lock: \(errno)") }
        }
        let waiting: DispatchSemaphore = DispatchSemaphore(value: 0)
        let scanned: DispatchSemaphore = DispatchSemaphore(value: 0)
        let refresh: Task<IndexSummary, any Error> = Task.detached(priority: .utility) {
            try await index.refresh(root: root.path, mode: .full, receiveEvent: { event in
                if case .waitingForWriter = event { waiting.signal() }
                if case .batch = event { scanned.signal() }
            }, isCancelled: { false })
        }
        let attempted: DispatchTimeoutResult = await waitForDatabaseSignal(waiting, timeout: .now() + 2)
        #expect(attempted == .success)
        let scannedWhileLocked: DispatchTimeoutResult = await waitForDatabaseSignal(scanned, timeout: .now() + 0.2)
        #expect(scannedWhileLocked == .timedOut)
        guard flock(descriptor, LOCK_UN) == 0 else { throw ScanError.systemCall(path: Data(lockPath.utf8), operation: "flock", errnoCode: errno) }
        let summary: IndexSummary = try await refresh.value
        #expect(summary.revision > previous.revision)
        #expect(summary.logicalBytes == 3)
    }
}
