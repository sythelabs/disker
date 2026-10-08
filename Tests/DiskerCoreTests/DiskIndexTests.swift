import Darwin
import Foundation
import Synchronization
import Testing
@testable import DiskerCore

@Suite(.serialized)
struct DiskIndexTests {
    @Test(arguments: [true, false])
    func overlappingSelectionsShareObservedFiles(childFirst: Bool) async throws {
        let fixture: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("disker-shared-tree-" + UUID().uuidString)
        let parent: URL = fixture.appendingPathComponent("parent")
        let child: URL = parent.appendingPathComponent("child")
        let file: URL = child.appendingPathComponent("nested/file")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        try Data(repeating: 1, count: 17).write(to: file)
        try Data(repeating: 2, count: 3).write(to: parent.appendingPathComponent("sibling"))
        let cache: URL = fixture.appendingPathComponent("cache/index.sqlite")
        let index: DiskIndex = try DiskIndex(databaseURL: cache)
        let first: URL = childFirst ? child : parent
        let second: URL = childFirst ? parent : child
        _ = try await index.refresh(root: first.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })

        let observed: IndexedNode? = try await index.node(root: second.path, path: Data(file.path.utf8))
        #expect(observed?.entry.metadata.logicalBytes == 17, "A file already observed through another selection must be immediately available")
        let cached: IndexSummary? = try await index.cachedSummary(root: second.path)
        #expect(cached != nil, "Ancestor and descendant views must project the shared cache before another traversal")
        #expect(cached?.logicalBytes == 17)
        #expect(cached?.nodeCount == (childFirst ? 4 : 3))
        #expect(try await index.cachedSummary(root: child.path)?.isComplete == true, "Completed child coverage must be shared before selecting another folder")
        let progress: IndexProgress = try #require(try await index.cachedProgress(root: second.path))
        #expect(progress.entriesObserved == cached?.nodeCount)
        #expect(progress.completionFraction > 0, "Changing the view must restore observed directory work")
        #expect(try await index.cachedSummary(root: "/")?.logicalBytes == (childFirst ? 17 : 20))
        #expect(try await index.cachedSummary(root: "/")?.isComplete == false)

        let refreshed: IndexSummary = try await index.refresh(root: second.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(refreshed.logicalBytes == (childFirst ? 20 : 17))
        #expect(try await index.cachedSummary(root: "/")?.logicalBytes == 20)
        #expect(refreshed.nodeCount == (childFirst ? 5 : 3))
        let reopened: DiskIndex = try DiskIndex(databaseURL: cache)
        #expect(try await reopened.node(root: parent.path, path: Data(file.path.utf8)) == reopened.node(root: child.path, path: Data(file.path.utf8)))
    }

    @Test func interruptedParentScanSharesCompletedChildBeforeParentFinishes() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-shared-partial-" + UUID().uuidString).resolvingSymlinksInPath()
        let parent: URL = fixture.appendingPathComponent("parent")
        let child: URL = parent.appendingPathComponent("a")
        let other: URL = parent.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        for number: Int in 0..<600 {
            try Data([1]).write(to: child.appendingPathComponent("file-\(number)"))
            try Data([2]).write(to: other.appendingPathComponent("file-\(number)"))
        }
        let cache: URL = fixture.appendingPathComponent("cache/index.sqlite")
        let index: DiskIndex = try DiskIndex(databaseURL: cache)
        let cancelled: Mutex<Bool> = Mutex(false)
        await #expect(throws: ScanError.cancelled) {
            try await index.refresh(root: parent.path, mode: .automatic, receiveEvent: { event in
                if case .progress(let progress) = event, progress.completionFraction > 0.4 {
                    cancelled.withLock { $0 = true }
                }
            }, isCancelled: { cancelled.withLock { $0 } })
        }
        let reopened: DiskIndex = try DiskIndex(databaseURL: cache)
        #expect(try await reopened.node(root: child.path, path: Data(child.appendingPathComponent("file-0").path.utf8))?.entry.metadata.logicalBytes == 1)
        #expect(try await reopened.cachedSummary(root: child.path)?.logicalBytes == 600)
        #expect(try await reopened.cachedSummary(root: child.path)?.isComplete == true, "Completed child coverage must survive interruption and reopening")
        let progress: IndexProgress = try #require(try await reopened.cachedProgress(root: child.path))
        #expect(progress.entriesObserved == 601)
        #expect(progress.completionFraction == 0.95)
        let resumed: IndexSummary = try await reopened.refresh(root: child.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        #expect(resumed.logicalBytes == 600)
        #expect(resumed.nodeCount == progress.entriesObserved)
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func selectedColumnsSortTheWholeDirectoryBeforePaging(order: SortOrder) async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-columns-" + UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder2"), withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        try Data(repeating: 1, count: 65_536).write(to: root.appendingPathComponent("folder10"))
        try Data([1]).write(to: root.appendingPathComponent("folder2/child2"))
        try Data([1]).write(to: root.appendingPathComponent("folder2/child10"))
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache/index.sqlite"))
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let expected: [(NodeSortColumn, [String])] = [
            (.name, order == .forward ? ["folder1", "folder2", "folder10"] : ["folder10", "folder2", "folder1"]),
            (.allocatedSize, order == .forward ? ["folder1", "folder2", "folder10"] : ["folder10", "folder2", "folder1"]),
            (.sizeProportion, order == .forward ? ["folder1", "folder2", "folder10"] : ["folder10", "folder2", "folder1"]),
            (.items, order == .forward ? ["folder1", "folder10", "folder2"] : ["folder2", "folder10", "folder1"])
        ]
        for (column, names): (NodeSortColumn, [String]) in expected {
            let sort: NodeSort = NodeSort(column: column, order: order)
            let first: [IndexedNode] = try await index.children(root: root.path, directory: Data(root.path.utf8), offset: 0, limit: 1, sort: sort)
            let rest: [IndexedNode] = try await index.children(root: root.path, directory: Data(root.path.utf8), offset: 1, limit: 10, sort: sort)
            #expect((first + rest).map { String(decoding: $0.entry.name, as: UTF8.self) } == names)
        }
        let dated: [IndexedNode] = try await index.children(root: root.path, directory: Data(root.path.utf8), offset: 0, limit: 10, sort: NodeSort(column: .lastOpened, order: order))
        #expect(dated.count == 3)
        if let missing: Int = dated.firstIndex(where: { $0.lastOpenedDate == nil }) {
            #expect(dated.dropFirst(missing).allSatisfy { $0.lastOpenedDate == nil })
        }
        let dates: [Date] = dated.compactMap(\.lastOpenedDate)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { order == .forward ? $0 <= $1 : $0 >= $1 })
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func lastOpenedSortUsesDatesAndKeepsUnavailableDatesLast(order: SortOrder) {
        let timestamp: FileTimestamp = FileTimestamp(seconds: 0, nanoseconds: 0)
        let metadata: FileMetadata = FileMetadata(kind: .regularFile, device: 1, inode: 1, linkCount: 1, mode: 0, ownerID: 0, groupID: 0, logicalBytes: 1, allocatedBytes: 1, birthTime: timestamp, modificationTime: timestamp, changeTime: timestamp, accessTime: timestamp, flags: 0)
        let values: [(String, Date?)] = [("unknown10", nil), ("recent", Date(timeIntervalSince1970: 200)), ("unknown2", nil), ("older", Date(timeIntervalSince1970: 100))]
        let nodes: [IndexedNode] = values.map { name, opened in
            IndexedNode(entry: ScanEntry(path: Data(("/root/" + name).utf8), parentPath: Data("/root".utf8), name: Data(name.utf8), metadata: metadata), subtreeLogicalBytes: 1, subtreeAllocatedBytes: 1, subtreeNodeCount: 1, aliasTargetPath: nil, lastOpenedDate: opened)
        }
        let names: [String] = nodes.sorted(using: NodeSort(column: .lastOpened, order: order)).map { String(decoding: $0.entry.name, as: UTF8.self) }
        #expect(names == (order == .forward ? ["older", "recent", "unknown2", "unknown10"] : ["recent", "older", "unknown2", "unknown10"]))
    }

    @Test func equalSizeNamesUseFinderOrderAcrossPages() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-sorting-" + UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        for name: String in ["file10", "file2", "file1"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache/index.sqlite"))
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let first: [IndexedNode] = try await index.children(root: root.path, directory: Data(root.path.utf8), offset: 0, limit: 2)
        let second: [IndexedNode] = try await index.children(root: root.path, directory: Data(root.path.utf8), offset: 2, limit: 2)
        #expect((first + second).map { String(decoding: $0.entry.name, as: UTF8.self) } == ["file1", "file2", "file10"])
    }

    @Test func indexProgressIsMonotonicAndCompletesAfterFilesystemWork() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache/index.sqlite"))
        let events: Mutex<[IndexEvent]> = Mutex([])
        let summary: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { event in events.withLock { $0.append(event) } }, isCancelled: { false })
        let captured: [IndexEvent] = events.withLock { $0 }
        let fractions: [Double] = captured.compactMap { event in
            if case let .progress(progress) = event { return progress.completionFraction }
            return nil
        }
        #expect(fractions.contains { $0 > 0 && $0 < 1 })
        #expect(fractions.last == 1)
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        guard case .completed = captured.last else { Issue.record("Missing committed completion event"); return }
        #expect(try await index.cachedSummary(root: root.path)?.revision == summary.revision)

        events.withLock { $0.removeAll() }
        _ = try await index.refresh(root: root.path, mode: .directories([Data(root.appendingPathComponent("a").path.utf8), Data(root.appendingPathComponent("b").path.utf8)]), receiveEvent: { event in events.withLock { $0.append(event) } }, isCancelled: { false })
        let incremental: [Double] = events.withLock { captured in
            captured.compactMap { event in
                if case let .progress(progress) = event { return progress.completionFraction }
                return nil
            }
        }
        #expect(incremental.first == 0.95)
        #expect(incremental.dropLast().allSatisfy { $0 < 1 })
        #expect(incremental.last == 1)
        #expect(zip(incremental, incremental.dropFirst()).allSatisfy { $0 <= $1 })
        let incrementalEvents: [IndexEvent] = events.withLock { $0 }
        let observedEntries: Int64 = incrementalEvents.reduce(0) { total, event in
            if case let .batch(entries) = event { return total + Int64(entries.count) }
            return total
        }
        let finalProgress: IndexProgress? = incrementalEvents.compactMap { event in
            if case let .progress(progress) = event { return progress }
            return nil
        }.last
        #expect(finalProgress?.entriesObserved == summary.nodeCount)
        #expect(observedEntries > 0)
    }

    @Test func incrementalProgressWaitsForNewSubtrees() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache/index.sqlite"))
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let file: URL = root.appendingPathComponent("new/deep/file")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        let events: Mutex<[IndexEvent]> = Mutex([])
        _ = try await index.refresh(root: root.path, mode: .directories([Data(root.path.utf8)]), receiveEvent: { event in events.withLock { $0.append(event) } }, isCancelled: { false })
        let captured: [IndexEvent] = events.withLock { $0 }
        let fileBatch: Int = try #require(captured.firstIndex { event in
            if case let .batch(entries) = event { return entries.contains { $0.path == Data(file.path.utf8) } }
            return false
        })
        #expect(captured[..<fileBatch].contains { event in
            if case let .progress(progress) = event { return progress.completionFraction > 0 && progress.completionFraction < 1 }
            return false
        })
        #expect(!captured[..<fileBatch].contains { event in
            if case let .progress(progress) = event { return progress.completionFraction == 1 }
            return false
        })
        #expect(try await index.node(root: root.path, path: Data(file.path.utf8)) != nil)
    }

    @Test func cancellationRetainsPartialProgressAndCommittedSnapshot() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache/index.sqlite"))
        let previous: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let cancelled: Mutex<Bool> = Mutex(false)
        let fractions: Mutex<[Double]> = Mutex([])
        await #expect(throws: ScanError.cancelled) {
            try await index.refresh(root: root.path, mode: .full, receiveEvent: { event in
                if case let .progress(progress) = event {
                    fractions.withLock { $0.append(progress.completionFraction) }
                    if progress.completionFraction > 0 { cancelled.withLock { $0 = true } }
                }
            }, isCancelled: { cancelled.withLock { $0 } })
        }
        #expect(fractions.withLock { $0.contains { $0 > 0 && $0 < 1 } })
        #expect(fractions.withLock { !$0.contains(1) })
        #expect(try await index.cachedSummary(root: root.path)!.revision > previous.revision)
    }

    @Test(.enabled(if: geteuid() != 0))
    func selectedRootPermissionDenialIsReportedAsScanFailure() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if chmod(root.path, 0o700) != 0 { Issue.record("Could not restore fixture permissions: \(errno)") }
            do { try FileManager.default.removeItem(at: fixture) } catch { Issue.record(error) }
        }
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache/index.sqlite"))
        guard chmod(root.path, 0) == 0 else { throw ScanError.systemCall(path: Data(root.path.utf8), operation: "chmod", errnoCode: errno) }
        await #expect(throws: ScanError.systemCall(path: Data(root.path.utf8), operation: "open", errnoCode: EACCES)) {
            try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        }
        #expect(try await index.cachedSummary(root: root.path) == nil)
    }

    @Test func persistedTreeCanBeQueriedWithoutScanning() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 19).write(to: root.appendingPathComponent("nested/file"))
        let databaseURL: URL = fixture.appendingPathComponent("index.sqlite")
        let index: DiskIndex = try DiskIndex(databaseURL: databaseURL)
        let summary: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(summary.logicalBytes == 19)
        #expect(summary.nodeCount == 3)
        let reopened: DiskIndex = try DiskIndex(databaseURL: databaseURL)
        let cached: IndexSummary? = try await reopened.cachedSummary(root: root.path)
        #expect(cached?.logicalBytes == 19)
        let children: [IndexedNode] = try await reopened.children(root: root.path, directory: Data(root.path.utf8), offset: 0, limit: 100)
        #expect(children.count == 1)
        #expect(children.first?.subtreeLogicalBytes == 19)
        let leaf: IndexedNode? = try await reopened.node(root: root.path, path: Data(root.appendingPathComponent("nested/file").path.utf8))
        #expect(leaf?.entry.metadata.logicalBytes == 19)
    }

    @Test func reconciliationHandlesResizeCreateRenameDelete() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file: URL = root.appendingPathComponent("old")
        try Data(repeating: 1, count: 5).write(to: file)
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache.sqlite"))
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try Data(repeating: 2, count: 11).write(to: file)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("renamed"))
        try Data(repeating: 3, count: 7).write(to: root.appendingPathComponent("added"))
        let updated: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(updated.logicalBytes == 18)
        #expect(updated.nodeCount == 3)
        #expect(try await index.node(root: root.path, path: Data(file.path.utf8)) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("renamed"))
        let deleted: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(deleted.logicalBytes == 7)
        #expect(deleted.nodeCount == 2)
    }

    @Test func cancellationPreservesCommittedSnapshot() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root: URL = fixture.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("file"))
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache.sqlite"))
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try Data(repeating: 2, count: 25).write(to: root.appendingPathComponent("file"))
        await #expect(throws: ScanError.self) {
            try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { true })
        }
        #expect(try await index.cachedSummary(root: root.path)?.logicalBytes == 5)
    }

    @Test func retargetingKeepsIndependentCaches() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first: URL = fixture.appendingPathComponent("first")
        let second: URL = fixture.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: first.appendingPathComponent("file"))
        try Data(repeating: 1, count: 9).write(to: second.appendingPathComponent("file"))
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache.sqlite"))
        _ = try await index.refresh(root: first.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        _ = try await index.refresh(root: second.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(try await index.cachedSummary(root: first.path)?.logicalBytes == 3)
        #expect(try await index.cachedSummary(root: second.path)?.logicalBytes == 9)
    }

    @Test func directoryReplacedByFileRemovesDescendants() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root: URL = fixture.appendingPathComponent("root")
        let directory: URL = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: directory.appendingPathComponent("old"))
        let index: DiskIndex = try DiskIndex(databaseURL: fixture.appendingPathComponent("cache.sqlite"))
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try FileManager.default.removeItem(at: directory)
        try Data(repeating: 2, count: 3).write(to: directory)
        let summary: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        #expect(summary.logicalBytes == 3)
        #expect(summary.nodeCount == 2)
        #expect(try await index.node(root: root.path, path: Data(directory.appendingPathComponent("old").path.utf8)) == nil)
    }
}
