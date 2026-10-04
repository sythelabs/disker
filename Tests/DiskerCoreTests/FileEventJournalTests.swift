import CoreServices
import Foundation
import Testing
@testable import DiskerCore

private func removeJournalFixture(_ root: URL) {
    do {
        try FileManager.default.removeItem(at: root)
    } catch {
        Issue.record(error)
    }
}

@Suite("File event journal", .serialized)
struct FileEventJournalTests {
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

    @Test func rootFilesystemRequiresScanInsteadOfSingleVolumeReplay() throws {
        let journal: FileEventJournal = try FileEventJournal(rootPath: "/", checkpoint: nil, latency: 0.01)
        defer { journal.stop() }
        let replay: JournalReplay = try journal.replay(timeout: 5)
        #expect(replay.requiresFullScan)
        #expect(replay.checkpoint == nil)
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
        _ = try first.replay(timeout: 5)
        let checkpoint: JournalCheckpoint = try #require(try first.drain().checkpoint)
        first.stop()

        try Data("new and larger".utf8).write(to: modified)
        try FileManager.default.removeItem(at: deleted)
        try Data("created".utf8).write(to: root.appendingPathComponent("created"))
        let restarted: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: checkpoint, latency: 0.01)
        defer { restarted.stop() }
        let deadline: Date = Date().addingTimeInterval(5)
        var replay: JournalReplay = try restarted.replay(timeout: 5)
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
            let replay: JournalReplay = try journal.replay(timeout: 5)
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
        #expect(try journal.replay(timeout: 5).requiresFullScan)
    }

    @Test func drainIncludesChangesMadeWhileScanWouldBeRunning() throws {
        let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeJournalFixture(root) }
        let journal: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: nil, latency: 0.01)
        defer { journal.stop() }
        _ = try journal.replay(timeout: 5)
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
