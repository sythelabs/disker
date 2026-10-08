import CoreServices
import Foundation
import Synchronization
import Testing
@testable import DiskerCore

private func removeJournalFixture(_ root: URL) {
    do {
        try FileManager.default.removeItem(at: root)
    } catch {
        Issue.record(error)
    }
}

private func deliverJournalEvent(to buffer: JournalEventBuffer, flags: UInt32, eventID: UInt64) {
    deliverJournalEvent(to: buffer, path: "fixture/file", flags: flags, eventID: eventID)
}

private func deliverJournalEvent(to buffer: JournalEventBuffer, path: String, flags: UInt32, eventID: UInt64) {
    path.withCString { nativePath in
        var pointer: UnsafePointer<CChar> = nativePath
        var eventFlags: UInt32 = flags
        var identifier: UInt64 = eventID
        withUnsafeMutablePointer(to: &pointer) { paths in
            buffer.receive(count: 1, paths: UnsafeMutableRawPointer(paths), flags: &eventFlags, identifiers: &identifier)
        }
    }
}

@Suite("File event journal", .serialized)
struct FileEventJournalTests {
    @Test(arguments: ["fixture/cache", "fixture/cache/index.sqlite", "fixture/cache/index.sqlite-wal"])
    func excludedCacheEventsDoNotInvalidateTheirParent(path: String) {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: "journal", eventID: 10, requiresFullScan: false, expectsHistory: false, excludedPaths: [Data("/fixture/cache".utf8)])
        deliverJournalEvent(to: buffer, path: path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified), eventID: 11)
        #expect(!buffer.hasPendingChanges)
        let replay: JournalReplay = buffer.snapshot()
        #expect(replay.dirtyDirectories.isEmpty)
        #expect(replay.recursiveDirectories.isEmpty)
        #expect(!replay.requiresFullScan)
        #expect(replay.checkpoint == JournalCheckpoint(journalID: "journal", eventID: 11))
        deliverJournalEvent(to: buffer, path: "fixture/cache-neighbor/file", flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified), eventID: 12)
        #expect(buffer.hasPendingChanges)
        #expect(buffer.snapshot().dirtyDirectories == ["/fixture/cache-neighbor"])
        #expect(!buffer.hasPendingChanges)
    }

    @Test func excludedPathsCannotSuppressDroppedEventReconciliation() {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: "journal", eventID: 10, requiresFullScan: false, expectsHistory: false, excludedPaths: [Data("/fixture/cache".utf8)])
        deliverJournalEvent(to: buffer, path: "fixture/cache", flags: UInt32(kFSEventStreamEventFlagUserDropped), eventID: 11)
        #expect(buffer.hasPendingChanges)
        #expect(buffer.snapshot().requiresFullScan)
    }

    @Test(arguments: [Array(UInt64(11)...25), [UInt64](repeating: 25, count: 15), Array((UInt64(11)...25).reversed())])
    func activeHistoryReplayCanExceedItsInactivityTimeout(eventIDs: [UInt64]) throws {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: "journal", eventID: 10, requiresFullScan: false, expectsHistory: true)
        var identifiers: IndexingIterator<[UInt64]> = eventIDs.makeIterator()
        let start: ContinuousClock.Instant = ContinuousClock.now
        try buffer.waitForHistory(timeout: 0.1, isCancelled: {
            // Deliver at each wait iteration so queue scheduling cannot manufacture an idle gap.
            if let eventID: UInt64 = identifiers.next() {
                deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified), eventID: eventID)
            } else {
                deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagHistoryDone), eventID: 25)
            }
            return false
        })
        #expect(start.duration(to: .now) >= .milliseconds(200))
        let replay: JournalReplay = buffer.snapshot()
        #expect(replay.dirtyDirectories == ["/fixture"])
        #expect(replay.checkpoint == JournalCheckpoint(journalID: "journal", eventID: 25))
        #expect(!replay.requiresFullScan)
    }

    @Test(arguments: [false, true])
    func stalledHistoryReplayStillTimesOut(afterActivity: Bool) throws {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: "journal", eventID: 10, requiresFullScan: false, expectsHistory: true)
        if afterActivity {
            deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagItemIsFile), eventID: 11)
        }
        do {
            try buffer.waitForHistory(timeout: 0.02, isCancelled: { false })
            Issue.record("Incomplete journal replay returned without HistoryDone")
        } catch FileEventJournalError.replayTimedOut(let path, let timeout) {
            #expect(path == "/fixture")
            #expect(timeout == 0.02)
        }
        deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagHistoryDone), eventID: 11)
        try buffer.waitForHistory(timeout: 0.02, isCancelled: { false })
    }

    @Test(arguments: [false, true])
    func waitingForHistoryCanBeCancelled(whileReceivingEvents: Bool) throws {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: "journal", eventID: 10, requiresFullScan: false, expectsHistory: true)
        let cancelled: Mutex<Bool> = Mutex(false)
        let finished: DispatchSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue(label: "DiskerTests.JournalCancellation").async {
            defer { finished.signal() }
            for eventID: UInt64 in 11...13 {
                if whileReceivingEvents {
                    deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagItemIsFile), eventID: eventID)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            cancelled.withLock { $0 = true }
        }
        defer { finished.wait() }
        let start: ContinuousClock.Instant = .now
        #expect(throws: ScanError.cancelled) {
            try buffer.waitForHistory(timeout: 5, isCancelled: { cancelled.withLock { $0 } })
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func streamsWithoutHistoryReturnImmediately() throws {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: nil, eventID: 0, requiresFullScan: true, expectsHistory: false)
        try buffer.waitForHistory(timeout: 0, isCancelled: { false })
        #expect(buffer.snapshot().requiresFullScan)
    }

    @Test func historyCompletionPreservesDroppedEventInvalidation() throws {
        let buffer: JournalEventBuffer = JournalEventBuffer(rootPath: "/fixture", relativePath: "fixture", journalID: "journal", eventID: 10, requiresFullScan: false, expectsHistory: true)
        deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs), eventID: 11)
        deliverJournalEvent(to: buffer, flags: UInt32(kFSEventStreamEventFlagHistoryDone), eventID: 12)
        try buffer.waitForHistory(timeout: 0.01, isCancelled: { false })
        let replay: JournalReplay = buffer.snapshot()
        #expect(replay.requiresFullScan)
        #expect(replay.checkpoint == JournalCheckpoint(journalID: "journal", eventID: 12))
    }

    @Test func eventFlagsChooseSafeReconciliationScopes() {
        let root: String = "/fixture"
        let file: JournalEvent = JournalEvent(path: "/fixture/a/file", flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified), eventID: 12)
        let directory: JournalEvent = JournalEvent(path: "/fixture/new", flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated), eventID: 13)
        let scopes: JournalScopes = reconciliationScopes(events: [file, directory], rootPath: root)
        #expect(scopes.dirtyDirectories == ["/fixture", "/fixture/a"])
        #expect(scopes.recursiveDirectories == ["/fixture/new"])
        #expect(!scopes.requiresFullScan)
    }

    @Test(arguments: [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount])
    func unsafeJournalFlagsRequireFullReconciliation(flag: Int) {
        let event: JournalEvent = JournalEvent(path: "/fixture", flags: UInt32(flag), eventID: 12)
        let scopes: JournalScopes = reconciliationScopes(events: [event], rootPath: "/fixture")
        #expect(scopes.requiresFullScan)
    }

    @Test func coalescedEventsRequireRecursiveScanAndHistorySentinelHasNoPath() {
        let events: [JournalEvent] = [
            JournalEvent(path: "/fixture/a", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), eventID: 12),
            JournalEvent(path: "/outside", flags: UInt32(kFSEventStreamEventFlagHistoryDone), eventID: 13)
        ]
        let scopes: JournalScopes = reconciliationScopes(events: events, rootPath: "/fixture")
        #expect(scopes.recursiveDirectories == ["/fixture/a"])
        #expect(scopes.dirtyDirectories.isEmpty)
        #expect(!scopes.requiresFullScan)
    }

    @Test func eventsOutsideRootCannotBeSilentlyDropped() {
        let event: JournalEvent = JournalEvent(path: "/fixture-other/file", flags: UInt32(kFSEventStreamEventFlagItemIsFile), eventID: 12)
        #expect(reconciliationScopes(events: [event], rootPath: "/fixture").requiresFullScan)
    }

    @Test func hostJournalReopensWithoutDiscardingCoverage() throws {
        let journal: FileEventJournal = try FileEventJournal(rootPath: "/", checkpoint: nil, latency: 0.01)
        defer { journal.stop() }
        let replay: JournalReplay = try journal.replay(timeout: 5, isCancelled: { false })
        #expect(replay.requiresFullScan)
        let checkpoint: JournalCheckpoint = try #require(replay.checkpoint)
        journal.stop()
        let reopened: FileEventJournal = try FileEventJournal(rootPath: "/", checkpoint: checkpoint, latency: 0.01)
        defer { reopened.stop() }
        let resumed: JournalReplay = try reopened.replay(timeout: 5, isCancelled: { false })
        #expect(!resumed.requiresFullScan)
        #expect(resumed.checkpoint?.journalID == checkpoint.journalID)
    }

    @Test func restartReplaysCreatesModificationsAndDeletions() throws {
        let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeJournalFixture(root) }
        let modified: URL = root.appendingPathComponent("modified")
        let deleted: URL = root.appendingPathComponent("deleted")
        try Data("old".utf8).write(to: modified)
        try Data("delete".utf8).write(to: deleted)
        let first: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: nil, latency: 0.01)
        _ = try first.replay(timeout: 5, isCancelled: { false })
        let checkpoint: JournalCheckpoint = try #require(try first.drain().checkpoint)
        first.stop()

        try Data("new and larger".utf8).write(to: modified)
        try FileManager.default.removeItem(at: deleted)
        try Data("created".utf8).write(to: root.appendingPathComponent("created"))
        let restarted: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: checkpoint, latency: 0.01)
        defer { restarted.stop() }
        let deadline: Date = Date().addingTimeInterval(5)
        var replay: JournalReplay = try restarted.replay(timeout: 5, isCancelled: { false })
        while !replay.dirtyDirectories.contains(root.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            replay = try restarted.drain()
        }
        #expect(!replay.requiresFullScan)
        #expect(replay.dirtyDirectories.contains(root.path))
        #expect(try #require(replay.checkpoint).eventID >= checkpoint.eventID)
    }

    @Test func committedCheckpointDoesNotRepeatedlyReplayCreationEvents() throws {
        let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeJournalFixture(root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("file"))
        var checkpoint: JournalCheckpoint? = nil
        var settled: Bool = false
        let deadline: Date = Date().addingTimeInterval(5)
        while Date() < deadline {
            let journal: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: checkpoint, latency: 0.01)
            let replay: JournalReplay = try journal.replay(timeout: 5, isCancelled: { false })
            let committed: JournalCheckpoint = try #require(replay.checkpoint)
            checkpoint = committed
            journal.stop()
            if !replay.requiresFullScan && replay.dirtyDirectories.isEmpty && replay.recursiveDirectories.isEmpty {
                settled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(settled)
    }

    @Test func journalIdentityMismatchForcesFullScan() throws {
        let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeJournalFixture(root) }
        let journal: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: JournalCheckpoint(journalID: "different", eventID: 1), latency: 0.01)
        defer { journal.stop() }
        #expect(try journal.replay(timeout: 5, isCancelled: { false }).requiresFullScan)
    }

    @Test func drainIncludesChangesMadeWhileScanWouldBeRunning() throws {
        let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeJournalFixture(root) }
        let journal: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: nil, latency: 0.01)
        defer { journal.stop() }
        _ = try journal.replay(timeout: 5, isCancelled: { false })
        try Data("written during scan".utf8).write(to: root.appendingPathComponent("racing-file"))
        let deadline: Date = Date().addingTimeInterval(5)
        var drained: JournalReplay = try journal.drain()
        while !drained.dirtyDirectories.contains(root.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            drained = try journal.drain()
        }
        #expect(drained.dirtyDirectories.contains(root.path))
    }
}
