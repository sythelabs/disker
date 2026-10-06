import Darwin
import Dispatch
import Foundation
import GRDB
import Synchronization
import Testing
@testable import DiskerCore

private struct IncrementalFixture: Sendable {
    let container: URL
    let root: URL
    let database: URL
}

private enum IncrementalFixtureError: Error {
    case journalDidNotSettle(String)
    case unchangedRefreshStillEnumerates(Int64)
}

private enum RetryMutation: CaseIterable, Sendable {
    case remove
    case replaceWithFile
}

private enum ResumeMutation: CaseIterable, Sendable {
    case resize, addSubtree, remove, replaceWithFile, replaceRoot
}

private func incrementalFixture() throws -> IncrementalFixture {
    let container: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-incremental-\(UUID().uuidString)").resolvingSymlinksInPath()
    let root: URL = container.appendingPathComponent("root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return IncrementalFixture(container: container, root: root, database: container.appendingPathComponent("cache/index.sqlite"))
}

private func removeIncrementalFixture(_ fixture: IncrementalFixture) {
    do {
        try FileManager.default.removeItem(at: fixture.container)
    } catch {
        Issue.record(error)
    }
}

private func createIncrementalFiles(directory: URL, count: Int, bytes: Int) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index: Int in 0..<count {
        try Data(repeating: 1, count: bytes).write(to: directory.appendingPathComponent("file-\(index)"))
    }
}

private func mutateAfterJournalFence(root: URL, requiredDirectories: [String], mutate: () throws -> Void) throws {
    let journal: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: nil, latency: 0.01)
    defer { journal.stop() }
    let before: JournalReplay = try journal.replay(timeout: 5)
    try mutate()
    var seen: Set<String> = []
    var recursive: Set<String> = []
    var advanced: Bool = false
    let deadline: Date = Date().addingTimeInterval(5)
    while Date() < deadline {
        let update: JournalReplay = try journal.drain()
        seen.formUnion(update.dirtyDirectories)
        recursive.formUnion(update.recursiveDirectories)
        advanced = advanced || (update.checkpoint?.eventID ?? 0) > (before.checkpoint?.eventID ?? 0)
        let covered: Bool = requiredDirectories.allSatisfy { required in
            seen.contains(required) || recursive.contains { required == $0 || required.hasPrefix($0 + "/") }
        }
        if advanced && (covered || update.requiresFullScan) { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw IncrementalFixtureError.journalDidNotSettle(root.path)
}

private func unchangedSummary(index: DiskIndex, root: String) async throws -> IndexSummary {
    let deadline: Date = Date().addingTimeInterval(5)
    var lastEntries: Int64 = -1
    while Date() < deadline {
        let summary: IndexSummary = try await index.refresh(root: root, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        lastEntries = summary.metrics.entries
        if lastEntries == 0 { return summary }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw IncrementalFixtureError.unchangedRefreshStillEnumerates(lastEntries)
}

private struct IncrementalCallbackState: Sendable {
    var removedPath: Data?
    var events: [String]
}

private func waitForIncrementalSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

@Suite("Incremental index", .serialized)
struct IncrementalIndexTests {
    @Test(arguments: ResumeMutation.allCases)
    fileprivate func resumedScanReconcilesChangesMadeWhileClosed(mutation: ResumeMutation) async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let branch: URL = fixture.root.appendingPathComponent("a")
        try createIncrementalFiles(directory: branch, count: 1200, bytes: 3)
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("b"), count: 1200, bytes: 5)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let cancelled: Mutex<Bool> = Mutex(false)
        await #expect(throws: ScanError.cancelled) {
            try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
                if case .progress(let progress) = event, progress.completionFraction > 0.4 { cancelled.withLock { $0 = true } }
            }, isCancelled: { cancelled.withLock { $0 } })
        }
        var expectedBytes: UInt64 = 9600
        var expectedCount: Int64 = 2403
        try mutateAfterJournalFence(root: fixture.root, requiredDirectories: [branch.path]) {
            switch mutation {
            case .resize:
                try Data(repeating: 2, count: 19).write(to: branch.appendingPathComponent("file-0"))
                expectedBytes += 16
            case .addSubtree:
                try createIncrementalFiles(directory: branch.appendingPathComponent("new"), count: 1, bytes: 37)
                expectedBytes += 37
                expectedCount += 2
            case .remove:
                try FileManager.default.removeItem(at: branch)
                expectedBytes = 6000
                expectedCount = 1202
            case .replaceWithFile:
                try FileManager.default.removeItem(at: branch)
                try Data(repeating: 2, count: 11).write(to: branch)
                expectedBytes = 6011
                expectedCount = 1203
            case .replaceRoot:
                try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appendingPathComponent("old-root"))
                try createIncrementalFiles(directory: fixture.root, count: 1, bytes: 9)
                expectedBytes = 9
                expectedCount = 2
            }
        }
        let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let resumed: IndexSummary = try await reopened.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(resumed.logicalBytes == expectedBytes)
        #expect(resumed.nodeCount == expectedCount)
        #expect(resumed.isComplete)
        if [.remove, .replaceWithFile, .replaceRoot].contains(mutation) {
            #expect(try await reopened.node(root: fixture.root.path, path: Data(branch.appendingPathComponent("file-0").path.utf8)) == nil)
        }
    }

    @Test func interruptedInitialScanRestoresProgressAndFinishesAfterReopening() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("a"), count: 1200, bytes: 3)
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("b"), count: 1200, bytes: 5)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let cancelled: Mutex<Bool> = Mutex(false)
        let savedProgress: Mutex<Double> = Mutex(0)
        await #expect(throws: ScanError.cancelled) {
            try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
                if case .progress(let progress) = event, progress.completionFraction > 0.4 {
                    savedProgress.withLock { $0 = progress.completionFraction }
                    cancelled.withLock { $0 = true }
                }
            }, isCancelled: { cancelled.withLock { $0 } })
        }
        #expect(try await index.cachedSummary(root: fixture.root.path) == nil)
        let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let firstProgress: Mutex<IndexProgress?> = Mutex(nil)
        let summary: IndexSummary = try await reopened.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { event in
            if case .progress(let progress) = event { firstProgress.withLock { if $0 == nil { $0 = progress } } }
        }, isCancelled: { false })
        #expect(firstProgress.withLock { $0?.completionFraction } == savedProgress.withLock { $0 })
        #expect(firstProgress.withLock { $0?.entriesObserved ?? 0 } >= 1203)
        #expect(summary.logicalBytes == 9600)
        #expect(summary.nodeCount == 2403)
        #expect(summary.isComplete)
        #expect(summary.metrics.entries < 2403, "The completed branch must not be enumerated again")
        #expect(try await reopened.node(root: fixture.root.path, path: Data(fixture.root.appendingPathComponent("a").path.utf8))?.subtreeLogicalBytes == 3600)
    }

    @Test func repeatedInterruptionsRetainCompletedBranchesAndRetryOnlyTheUnfinishedDirectory() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("a"), count: 1200, bytes: 3)
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("b"), count: 2400, bytes: 5)
        var retainedEntries: Int64 = 0
        for attempt: Int in 0..<3 {
            let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
            let cancelled: Mutex<Bool> = Mutex(false)
            let observed: Mutex<Int64> = Mutex(0)
            let first: Mutex<IndexProgress?> = Mutex(nil)
            await #expect(throws: ScanError.cancelled) {
                try await reopened.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { event in
                    guard case .progress(let progress) = event else { return }
                    first.withLock { if $0 == nil { $0 = progress } }
                    observed.withLock { $0 = progress.entriesObserved }
                    if (attempt == 0 && progress.completionFraction > 0.4) || (attempt > 0 && progress.entriesObserved > 1700) {
                        cancelled.withLock { $0 = true }
                    }
                }, isCancelled: { cancelled.withLock { $0 } })
            }
            if attempt > 0 {
                #expect(first.withLock { $0?.entriesObserved } == retainedEntries)
                #expect(first.withLock { $0?.completionFraction ?? 0 } > 0.4)
            }
            retainedEntries = observed.withLock { $0 }
        }
        let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let summary: IndexSummary = try await reopened.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(summary.logicalBytes == 15600)
        #expect(summary.nodeCount == 3603)
        #expect(summary.metrics.entries < 3603)
        #expect(summary.isComplete)
    }

    @Test func explicitDirectoriesImmediatelyReconcileFileOperationsWithoutWalkingUntouchedBranches() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let edited: URL = fixture.root.appendingPathComponent("edited")
        let untouched: URL = fixture.root.appendingPathComponent("untouched")
        try createIncrementalFiles(directory: edited, count: 2, bytes: 3)
        try createIncrementalFiles(directory: untouched, count: 600, bytes: 1)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        _ = try await unchangedSummary(index: index, root: fixture.root.path)
        try FileManager.default.moveItem(at: edited.appendingPathComponent("file-0"), to: edited.appendingPathComponent("renamed"))
        try FileManager.default.removeItem(at: edited.appendingPathComponent("file-1"))
        try Data(repeating: 1, count: 7).write(to: edited.appendingPathComponent("added"))
        let observed: Mutex<[Data]> = Mutex([])
        let updated: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .directories([Data(edited.path.utf8)]), receiveEvent: { event in
            if case .batch(let entries) = event { observed.withLock { $0.append(contentsOf: entries.map(\.path)) } }
        }, isCancelled: { false })
        #expect(updated.logicalBytes == 610)
        #expect(try await index.node(root: fixture.root.path, path: Data(edited.appendingPathComponent("file-0").path.utf8)) == nil)
        #expect(try await index.node(root: fixture.root.path, path: Data(edited.appendingPathComponent("file-1").path.utf8)) == nil)
        #expect(try await index.node(root: fixture.root.path, path: Data(edited.appendingPathComponent("renamed").path.utf8)) != nil)
        #expect(try await index.node(root: fixture.root.path, path: Data(edited.appendingPathComponent("added").path.utf8)) != nil)
        #expect(!observed.withLock { $0 }.contains { $0.starts(with: Data((untouched.path + "/").utf8)) })
    }

    @Test func explicitDirectoryRefreshRejectsPathsOutsideItsRoot() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        await #expect(throws: IndexError.self) {
            try await index.refresh(root: fixture.root.path, mode: .directories([Data(fixture.container.path.utf8)]), receiveEvent: { _ in }, isCancelled: { false })
        }
        #expect(try await index.cachedSummary(root: fixture.root.path) == nil)
    }

    @Test func cacheDirectoryRemainsExcludedWhenDatabaseUsesAnotherFilesystemPath() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root, count: 1, bytes: 3)
        let alias: URL = fixture.container.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let database: URL = alias.appendingPathComponent("cache/index.sqlite")
        let index: DiskIndex = try DiskIndex(databaseURL: database)
        let summary: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(summary.logicalBytes == 3)
        #expect(summary.nodeCount == 2)
        #expect(try await index.node(root: fixture.root.path, path: Data(fixture.root.appendingPathComponent("cache/index.sqlite").path.utf8)) == nil)
        #expect(summary.issues.contains { $0.kind == .excluded && $0.path == Data(fixture.root.appendingPathComponent("cache").path.utf8) })
    }

    @Test func cachedQueriesFinishWhileRefreshHasUncommittedStreamingBatches() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root, count: 1, bytes: 3)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("new"), count: 600, bytes: 2)
        let entered: DispatchSemaphore = DispatchSemaphore(value: 0)
        let release: DispatchSemaphore = DispatchSemaphore(value: 0)
        let queryFinished: DispatchSemaphore = DispatchSemaphore(value: 0)
        let paused: Mutex<Bool> = Mutex(false)
        defer { release.signal() }
        let refresh: Task<IndexSummary, any Error> = Task.detached(priority: .utility) {
            try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
                guard case .batch = event else { return }
                let shouldPause: Bool = paused.withLock { state in
                    if state { return false }
                    state = true
                    return true
                }
                if shouldPause {
                    entered.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut { Issue.record("Timed out waiting to release fixture scan") }
                }
            }, isCancelled: { false })
        }
        let scanStarted: DispatchTimeoutResult = await waitForIncrementalSignal(entered, timeout: .now() + 2)
        #expect(scanStarted == .success)
        let query: Task<([IndexedNode], IndexSummary?), any Error> = Task.detached(priority: .utility) {
            defer { queryFinished.signal() }
            let children: [IndexedNode] = try await index.children(root: fixture.root.path, directory: Data(fixture.root.path.utf8), offset: 0, limit: 10)
            let summary: IndexSummary? = try await index.cachedSummary(root: fixture.root.path)
            return (children, summary)
        }
        let queryCompleted: DispatchTimeoutResult = await waitForIncrementalSignal(queryFinished, timeout: .now() + 2)
        #expect(queryCompleted == .success)
        release.signal()
        let (children, summary): ([IndexedNode], IndexSummary?) = try await query.value
        #expect(children.count == 1)
        #expect(summary?.revision == previous.revision)
        #expect(summary?.logicalBytes == 3)
        let updated: IndexSummary = try await refresh.value
        #expect(updated.logicalBytes == 1_203)
    }

    @Test func restartedAutomaticRefreshReconcilesChangedBranchesWithoutWalkingUntouchedTree() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let untouched: URL = fixture.root.appendingPathComponent("untouched")
        let edited: URL = fixture.root.appendingPathComponent("edited/nested")
        let deleted: URL = fixture.root.appendingPathComponent("deleted")
        let renamed: URL = fixture.root.appendingPathComponent("renamed")
        let destination: URL = fixture.root.appendingPathComponent("destination")
        try createIncrementalFiles(directory: untouched, count: 600, bytes: 1)
        try createIncrementalFiles(directory: edited, count: 1, bytes: 5)
        try createIncrementalFiles(directory: deleted, count: 1, bytes: 7)
        try createIncrementalFiles(directory: renamed, count: 1, bytes: 9)
        let original: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let initial: IndexSummary = try await original.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let untouchedBefore: IndexedNode = try #require(try await original.node(root: fixture.root.path, path: Data(untouched.path.utf8)))
        try mutateAfterJournalFence(root: fixture.root, requiredDirectories: [fixture.root.path, edited.path]) {
            try Data(repeating: 2, count: 23).write(to: edited.appendingPathComponent("file-0"))
            try FileManager.default.removeItem(at: deleted)
            try FileManager.default.moveItem(at: renamed, to: destination)
        }
        let restarted: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let cached: IndexSummary = try #require(try await restarted.cachedSummary(root: fixture.root.path))
        #expect(cached.logicalBytes == initial.logicalBytes)
        let updated: IndexSummary = try await restarted.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(updated.logicalBytes == 632)
        #expect(updated.nodeCount == 607)
        #expect(updated.isComplete)
        #expect(updated.metrics.contentBytesRead == 0)
        #expect(updated.metrics.entries < initial.metrics.entries / 4)
        #expect(try await restarted.node(root: fixture.root.path, path: Data(deleted.path.utf8)) == nil)
        #expect(try await restarted.node(root: fixture.root.path, path: Data(renamed.appendingPathComponent("file-0").path.utf8)) == nil)
        #expect(try await restarted.node(root: fixture.root.path, path: Data(destination.appendingPathComponent("file-0").path.utf8))?.entry.metadata.logicalBytes == 9)
        let untouchedAfter: IndexedNode = try #require(try await restarted.node(root: fixture.root.path, path: Data(untouched.path.utf8)))
        #expect(untouchedAfter.entry.metadata.inode == untouchedBefore.entry.metadata.inode)
        #expect(untouchedAfter.entry.metadata.modificationTime == untouchedBefore.entry.metadata.modificationTime)
        #expect(untouchedAfter.subtreeLogicalBytes == untouchedBefore.subtreeLogicalBytes)
        #expect(untouchedAfter.subtreeNodeCount == untouchedBefore.subtreeNodeCount)
    }

    @Test func reopenedIndexReadsCommittedSnapshotWhileAnotherIndexRefreshIsPaused() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root, count: 1, bytes: 3)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("new"), count: 600, bytes: 2)
        let entered: DispatchSemaphore = DispatchSemaphore(value: 0)
        let release: DispatchSemaphore = DispatchSemaphore(value: 0)
        let queryFinished: DispatchSemaphore = DispatchSemaphore(value: 0)
        let paused: Mutex<Bool> = Mutex(false)
        defer { release.signal() }
        let refresh: Task<IndexSummary, any Error> = Task.detached(priority: .utility) {
            try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
                guard case .batch = event else { return }
                let shouldPause: Bool = paused.withLock { state in
                    if state { return false }
                    state = true
                    return true
                }
                if shouldPause {
                    entered.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut { Issue.record("Timed out waiting to release fixture scan") }
                }
            }, isCancelled: { false })
        }
        let scanStarted: DispatchTimeoutResult = await waitForIncrementalSignal(entered, timeout: .now() + 2)
        #expect(scanStarted == .success)
        let query: Task<([IndexedNode], IndexSummary?), any Error> = Task.detached(priority: .utility) {
            defer { queryFinished.signal() }
            let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
            let children: [IndexedNode] = try await reopened.children(root: fixture.root.path, directory: Data(fixture.root.path.utf8), offset: 0, limit: 10)
            let summary: IndexSummary? = try await reopened.cachedSummary(root: fixture.root.path)
            return (children, summary)
        }
        let queryCompleted: DispatchTimeoutResult = await waitForIncrementalSignal(queryFinished, timeout: .now() + 2)
        #expect(queryCompleted == .success)
        release.signal()
        let (children, summary): ([IndexedNode], IndexSummary?) = try await query.value
        #expect(children.count == 1)
        #expect(summary?.revision == previous.revision)
        #expect(summary?.logicalBytes == 3)
        let updated: IndexSummary = try await refresh.value
        #expect(updated.logicalBytes == 1_203)
    }

    @Test func unchangedAutomaticRefreshReadsNoTreeEntriesAfterEventsSettle() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("nested"), count: 20, bytes: 3)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        _ = try await unchangedSummary(index: index, root: fixture.root.path)
        let unchanged: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(unchanged.metrics.entries == 0)
        #expect(unchanged.metrics.bulkCalls == 0)
        #expect(unchanged.logicalBytes == 60)
        #expect(unchanged.nodeCount == 22)
    }

    @Test func automaticDirectoryToFileReplacementRemovesAllFormerDescendants() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let replaced: URL = fixture.root.appendingPathComponent("replace")
        let nested: URL = replaced.appendingPathComponent("nested")
        try createIncrementalFiles(directory: nested, count: 2, bytes: 4)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try mutateAfterJournalFence(root: fixture.root, requiredDirectories: [fixture.root.path]) {
            try FileManager.default.removeItem(at: replaced)
            try Data(repeating: 2, count: 3).write(to: replaced)
        }
        let summary: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(summary.logicalBytes == 3)
        #expect(summary.nodeCount == 2)
        #expect(try await index.node(root: fixture.root.path, path: Data(replaced.path.utf8))?.entry.metadata.kind == .regularFile)
        #expect(try await index.node(root: fixture.root.path, path: Data(nested.appendingPathComponent("file-0").path.utf8)) == nil)
        #expect(try await index.children(root: fixture.root.path, directory: Data(replaced.path.utf8), offset: 0, limit: 10).isEmpty)
    }

    @Test func deletionAfterFirstStreamingBatchDoesNotLeaveAStaleRow() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root, count: 1_200, bytes: 1)
        let observer: Mutex<FileEventJournal> = Mutex(try FileEventJournal(rootPath: fixture.root.path, checkpoint: nil, latency: 0.01))
        defer { observer.withLock { $0.stop() } }
        let baseline: UInt64 = try observer.withLock { try $0.replay(timeout: 5).checkpoint?.eventID ?? 0 }
        let state: Mutex<IncrementalCallbackState> = Mutex(IncrementalCallbackState(removedPath: nil, events: []))
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let summary: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
            guard case .batch(let batch) = event else { return }
            let victim: ScanEntry? = state.withLock { state in
                guard state.removedPath == nil, let entry: ScanEntry = batch.first(where: { $0.metadata.kind == .regularFile }) else { return nil }
                state.removedPath = entry.path
                return entry
            }
            guard let victim: ScanEntry else { return }
            do {
                let victimPath: String = String(decoding: victim.path, as: UTF8.self)
                try FileManager.default.removeItem(atPath: victimPath)
                let deadline: Date = Date().addingTimeInterval(5)
                var observed: Bool = false
                while Date() < deadline {
                    let update: JournalReplay = try observer.withLock { try $0.drain() }
                    if (update.checkpoint?.eventID ?? 0) > baseline && (update.dirtyDirectories.contains(fixture.root.path) || update.recursiveDirectories.contains(fixture.root.path)) {
                        observed = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if !observed { throw IncrementalFixtureError.journalDidNotSettle(fixture.root.path) }
            } catch {
                Issue.record(error)
            }
        }, isCancelled: { false })
        let removed: Data = try #require(state.withLock { $0.removedPath })
        #expect(summary.logicalBytes == 1_199)
        #expect(summary.nodeCount == 1_200)
        #expect(try await index.node(root: fixture.root.path, path: removed) == nil)
    }

    @Test func batchesAndProgressArriveBeforeCompletion() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        try createIncrementalFiles(directory: fixture.root, count: 1_200, bytes: 1)
        let events: Mutex<[String]> = Mutex([])
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
            let name: String
            switch event {
            case .started: name = "started"
            case .waitingForWriter: name = "waiting_for_writer"
            case .writerAcquired: name = "writer_acquired"
            case .batch: name = "batch"
            case .progress: name = "progress"
            case .completed: name = "completed"
            }
            events.withLock { $0.append(name) }
        }, isCancelled: { false })
        let observed: [String] = events.withLock { $0 }
        #expect(observed.first == "started")
        #expect(observed.last == "completed")
        #expect(observed.filter { $0 == "batch" }.count >= 3)
        #expect(observed.contains("progress"))
        #expect(observed.dropLast().contains("batch"))
    }

    @Test func cancellationAfterStreamingBatchKeepsPersistedTreeAndCheckpointUnchanged() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let file: URL = fixture.root.appendingPathComponent("original")
        try Data(repeating: 1, count: 5).write(to: file)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let previous: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let connection: DatabaseQueue = try DatabaseQueue(path: fixture.database.path)
        let previousCheckpoint: Data = try #require(await connection.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM roots WHERE root=?", arguments: [fixture.root.path])
        })
        try Data(repeating: 2, count: 25).write(to: file)
        let added: URL = fixture.root.appendingPathComponent("new")
        try createIncrementalFiles(directory: added, count: 600, bytes: 1)
        let cancelled: Mutex<Bool> = Mutex(false)
        let streamed: Mutex<Int> = Mutex(0)
        await #expect(throws: ScanError.cancelled) {
            try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
                guard case .batch = event else { return }
                streamed.withLock { $0 += 1 }
                cancelled.withLock { $0 = true }
            }, isCancelled: { cancelled.withLock { $0 } })
        }
        #expect(streamed.withLock { $0 } > 0)
        let reopened: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        #expect(try await reopened.cachedSummary(root: fixture.root.path) == previous)
        #expect(try await reopened.node(root: fixture.root.path, path: Data(file.path.utf8))?.entry.metadata.logicalBytes == 5)
        #expect(try await reopened.node(root: fixture.root.path, path: Data(added.path.utf8)) == nil)
        let currentCheckpoint: Data? = try await connection.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM roots WHERE root=?", arguments: [fixture.root.path])
        }
        #expect(currentCheckpoint == previousCheckpoint)
    }

    @Test(arguments: RetryMutation.allCases)
    fileprivate func transientIssueDirectoryChangingImmediatelyBeforeRetryIsReconciled(mutation: RetryMutation) async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let branch: URL = fixture.root.appendingPathComponent("branch")
        try createIncrementalFiles(directory: fixture.root, count: 1, bytes: 3)
        try createIncrementalFiles(directory: branch, count: 2, bytes: 8)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let quiet: IndexSummary = try await unchangedSummary(index: index, root: fixture.root.path)
        let issue: ScanIssue = ScanIssue(kind: .changedDuringScan, path: Data(branch.path.utf8), operation: "verifyDirectory", errnoCode: 0)
        let incomplete: IndexSummary = IndexSummary(root: quiet.root, logicalBytes: quiet.logicalBytes, allocatedBytes: quiet.allocatedBytes, nodeCount: quiet.nodeCount, revision: quiet.revision, lastScanDate: quiet.lastScanDate, isComplete: false, issues: [issue], metrics: quiet.metrics)
        let connection: DatabaseQueue = try DatabaseQueue(path: fixture.database.path)
        try await connection.write { db in
            try db.execute(sql: "UPDATE roots SET summary=? WHERE root=?", arguments: [try JSONEncoder().encode(incomplete), fixture.root.path])
        }
        let checks: Mutex<Int> = Mutex(0)
        let removed: Mutex<Bool> = Mutex(false)
        let updated: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: {
            let beforeSubtreeOpen: Bool = checks.withLock { state in
                state += 1
                return state == 2
            }
            if beforeSubtreeOpen {
                do {
                    try FileManager.default.removeItem(at: branch)
                    if mutation == .replaceWithFile { try Data(repeating: 2, count: 7).write(to: branch) }
                    removed.withLock { $0 = true }
                } catch {
                    Issue.record(error)
                }
            }
            return false
        })
        #expect(removed.withLock { $0 })
        #expect(updated.isComplete)
        #expect(updated.logicalBytes == (mutation == .remove ? 3 : 10))
        #expect(updated.nodeCount == (mutation == .remove ? 2 : 3))
        #expect(updated.issues.isEmpty)
        let replacement: IndexedNode? = try await index.node(root: fixture.root.path, path: Data(branch.path.utf8))
        if mutation == .remove {
            #expect(replacement == nil)
        } else {
            #expect(replacement?.entry.metadata.kind == .regularFile)
            #expect(replacement?.entry.metadata.logicalBytes == 7)
        }
        #expect(try await index.node(root: fixture.root.path, path: Data(branch.appendingPathComponent("file-0").path.utf8)) == nil)
    }

    @Test(.enabled(if: geteuid() != 0))
    func automaticPermissionLossPreservesKnownSubtreeWithoutWalkingUntouchedBranches() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let restricted: URL = fixture.root.appendingPathComponent("restricted")
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("untouched"), count: 600, bytes: 1)
        try createIncrementalFiles(directory: restricted, count: 2, bytes: 8)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let initial: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        _ = try await unchangedSummary(index: index, root: fixture.root.path)
        try mutateAfterJournalFence(root: fixture.root, requiredDirectories: [restricted.path]) {
            guard chmod(restricted.path, 0) == 0 else { throw ScanError.systemCall(path: Data(restricted.path.utf8), operation: "chmod", errnoCode: errno) }
        }
        defer {
            if chmod(restricted.path, 0o700) != 0 { Issue.record("Could not restore fixture permissions: \(errno)") }
        }
        let denied: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(!denied.isComplete)
        #expect(denied.logicalBytes == 616)
        #expect(denied.nodeCount == initial.nodeCount)
        #expect(denied.metrics.entries < initial.metrics.entries / 4)
        #expect(denied.issues.contains { $0.kind == .permissionDenied && $0.path == Data(restricted.path.utf8) })
        #expect(try await index.node(root: fixture.root.path, path: Data(restricted.appendingPathComponent("file-0").path.utf8))?.entry.metadata.logicalBytes == 8)
        let quiet: IndexSummary = try await unchangedSummary(index: index, root: fixture.root.path)
        #expect(!quiet.isComplete)
        #expect(quiet.issues.contains { $0.kind == .permissionDenied && $0.path == Data(restricted.path.utf8) })
    }

    @Test(.enabled(if: geteuid() != 0))
    func unchangedPermissionDenialReusesCacheAndPermissionRecoveryOnlyScansChangedBranch() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let restricted: URL = fixture.root.appendingPathComponent("restricted")
        try createIncrementalFiles(directory: fixture.root.appendingPathComponent("untouched"), count: 600, bytes: 1)
        try createIncrementalFiles(directory: restricted, count: 2, bytes: 8)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        let initial: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try mutateAfterJournalFence(root: fixture.root, requiredDirectories: [restricted.path]) {
            guard chmod(restricted.path, 0) == 0 else { throw ScanError.systemCall(path: Data(restricted.path.utf8), operation: "chmod", errnoCode: errno) }
        }
        defer {
            if chmod(restricted.path, 0o700) != 0 { Issue.record("Could not restore fixture permissions: \(errno)") }
        }
        let denied: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(!denied.isComplete)
        #expect(denied.logicalBytes == 616)
        #expect(denied.issues.contains { $0.kind == .permissionDenied && $0.path == Data(restricted.path.utf8) })
        let quiet: IndexSummary = try await unchangedSummary(index: index, root: fixture.root.path)
        #expect(!quiet.isComplete)
        #expect(quiet.metrics.entries == 0)
        #expect(quiet.issues.contains { $0.kind == .permissionDenied && $0.path == Data(restricted.path.utf8) })
        try mutateAfterJournalFence(root: fixture.root, requiredDirectories: [restricted.path]) {
            guard chmod(restricted.path, 0o700) == 0 else { throw ScanError.systemCall(path: Data(restricted.path.utf8), operation: "chmod", errnoCode: errno) }
            try Data(repeating: 2, count: 21).write(to: restricted.appendingPathComponent("file-0"))
        }
        let recovered: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(recovered.isComplete)
        #expect(recovered.logicalBytes == 629)
        #expect(recovered.metrics.entries < initial.metrics.entries / 4)
        #expect(!recovered.issues.contains { $0.kind == .permissionDenied })
    }

    @Test(.enabled(if: geteuid() != 0))
    func permissionLossPreservesPreviouslyKnownSubtreeAndMarksSnapshotIncomplete() async throws {
        let fixture: IncrementalFixture = try incrementalFixture()
        defer { removeIncrementalFixture(fixture) }
        let restricted: URL = fixture.root.appendingPathComponent("restricted")
        try createIncrementalFiles(directory: restricted, count: 2, bytes: 8)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.database)
        _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(chmod(restricted.path, 0) == 0)
        defer {
            if chmod(restricted.path, 0o700) != 0 { Issue.record("Could not restore fixture permissions: \(errno)") }
        }
        let incomplete: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(!incomplete.isComplete)
        #expect(incomplete.issues.contains { $0.kind == .permissionDenied && $0.path == Data(restricted.path.utf8) })
        #expect(incomplete.logicalBytes == 16)
        #expect(try await index.node(root: fixture.root.path, path: Data(restricted.appendingPathComponent("file-0").path.utf8))?.entry.metadata.logicalBytes == 8)
    }
}
