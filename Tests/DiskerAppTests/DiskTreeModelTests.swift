import Dispatch
import DiskerCore
import Foundation
import GRDB
import Synchronization
import Testing
@testable import Disker

private struct TreeFixture: Sendable {
    let container: URL
    let root: URL
    let cache: URL
}

private enum TreeFixtureError: Error {
    case timedOut(String)
}

private func treeFixture() throws -> TreeFixture {
    let container: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-tree-" + UUID().uuidString).resolvingSymlinksInPath()
    let root: URL = container.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TreeFixture(container: container, root: root, cache: container.appendingPathComponent("cache/index.sqlite"))
}

private func removeTreeFixture(_ fixture: TreeFixture) {
    do { try FileManager.default.removeItem(at: fixture.container) }
    catch { Issue.record(error) }
}

private func treeFiles(directory: URL, count: Int, bytes: Int) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for number: Int in 0..<count {
        try Data(repeating: UInt8(number % 251), count: bytes).write(to: directory.appendingPathComponent("file-\(number)"))
    }
}

private func cachedTree(fixture: TreeFixture) async throws -> DiskIndex {
    let index: DiskIndex = try DiskIndex(databaseURL: fixture.cache)
    _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
    let deadline: Date = Date().addingTimeInterval(5)
    while Date() < deadline {
        let summary: IndexSummary = try await index.refresh(root: fixture.root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        if summary.metrics.entries == 0 { return index }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TreeFixtureError.timedOut("settling cached tree")
}

@MainActor private func waitForTreeScan(_ model: DiskTreeModel) async throws {
    let deadline: Date = Date().addingTimeInterval(5)
    while model.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    if model.isScanning { throw TreeFixtureError.timedOut("waiting for model scan") }
}

private func waitForTreeSignal(_ signal: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: signal.wait(timeout: timeout))
        }
    }
}

@Suite("Disk tree model", .serialized)
@MainActor struct DiskTreeModelTests {
    @Test func repeatedPreviewScopeDoesNotCountFilesTwice() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        let file: URL = folder.appendingPathComponent("file-0")
        try treeFiles(directory: folder, count: 1, bytes: 8_192)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let rootEntry: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(fixture.root.path.utf8))).entry
        let folderEntry: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(folder.path.utf8))).entry
        let fileEntry: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(file.path.utf8))).entry
        let buffer: TreeScanBuffer = TreeScanBuffer(root: rootEntry.path, capturePreview: true, limit: 500)
        buffer.receive(.batch([rootEntry, folderEntry, fileEntry]))
        let before: IndexedNode = try #require(buffer.snapshot().nodes.first)
        let scope: ScanEntry = ScanEntry(path: folderEntry.path, parentPath: nil, name: folderEntry.name, metadata: folderEntry.metadata)
        buffer.receive(.batch([scope, fileEntry]))
        let after: IndexedNode = try #require(buffer.snapshot().nodes.first)
        #expect(after.subtreeLogicalBytes == before.subtreeLogicalBytes)
        #expect(after.subtreeAllocatedBytes == before.subtreeAllocatedBytes)
        #expect(after.subtreeNodeCount == before.subtreeNodeCount)
        #expect(after.subtreeNodeCount == 2)
    }

    @Test func previewIncludesDirectoryAllocatedBytesInItsBranchTotal() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        try treeFiles(directory: folder, count: 1, bytes: 8_192)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let rootEntry: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(fixture.root.path.utf8))).entry
        let folderEntry: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(folder.path.utf8))).entry
        let childEntry: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(folder.appendingPathComponent("file-0").path.utf8))).entry
        let metadata: FileMetadata = folderEntry.metadata
        let allocatedDirectory: FileMetadata = FileMetadata(kind: metadata.kind, device: metadata.device, inode: metadata.inode, linkCount: metadata.linkCount, mode: metadata.mode, ownerID: metadata.ownerID, groupID: metadata.groupID, logicalBytes: metadata.logicalBytes, allocatedBytes: 4_096, birthTime: metadata.birthTime, modificationTime: metadata.modificationTime, changeTime: metadata.changeTime, accessTime: metadata.accessTime, flags: metadata.flags)
        let directoryEntry: ScanEntry = ScanEntry(path: folderEntry.path, parentPath: folderEntry.parentPath, name: folderEntry.name, metadata: allocatedDirectory)
        let buffer: TreeScanBuffer = TreeScanBuffer(root: rootEntry.path, capturePreview: true, limit: 500)
        buffer.receive(.batch([rootEntry, directoryEntry, childEntry]))
        let node: IndexedNode = try #require(buffer.snapshot().nodes.first)
        #expect(node.subtreeAllocatedBytes == 4_096 + childEntry.metadata.allocatedBytes)
        #expect(node.subtreeLogicalBytes == childEntry.metadata.logicalBytes)
        #expect(node.subtreeNodeCount == 2)
    }

    @Test func previewSizeUpdatesDoNotMoveFoldersBetweenClicks() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let firstFolder: URL = fixture.root.appendingPathComponent("first")
        let secondFolder: URL = fixture.root.appendingPathComponent("second")
        try treeFiles(directory: firstFolder, count: 1, bytes: 4_096)
        try treeFiles(directory: secondFolder, count: 1, bytes: 32_768)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let root: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(fixture.root.path.utf8))).entry
        let first: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(firstFolder.path.utf8))).entry
        let second: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(secondFolder.path.utf8))).entry
        let firstFile: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(firstFolder.appendingPathComponent("file-0").path.utf8))).entry
        let secondFile: ScanEntry = try #require(try await index.node(root: fixture.root.path, path: Data(secondFolder.appendingPathComponent("file-0").path.utf8))).entry
        let buffer: TreeScanBuffer = TreeScanBuffer(root: root.path, capturePreview: true, limit: 500)
        buffer.receive(.batch([root, first, second, firstFile]))
        let before: [Data] = buffer.snapshot().nodes.map(\.entry.path)

        buffer.receive(.batch([secondFile]))
        let after: TreeScanPreview = buffer.snapshot()
        #expect(after.nodes.map(\.entry.path) == before, "Growing sizes moved a different folder into the row being clicked")
        #expect(after.nodes.last?.subtreeAllocatedBytes == secondFile.metadata.allocatedBytes + second.metadata.allocatedBytes)
    }

    @Test func nestedFoldersAndFilesCollapseAndReexpandWithParentProportions() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        let nested: URL = folder.appendingPathComponent("nested")
        try treeFiles(directory: fixture.root, count: 1, bytes: 4_096)
        try treeFiles(directory: folder, count: 1, bytes: 8_192)
        try treeFiles(directory: nested, count: 1, bytes: 16_384)
        _ = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        #expect(model.errorMessage == nil)
        #expect(model.rows.count == 3)
        #expect(model.rows.contains { $0.node?.entry.metadata.kind == .regularFile })
        #expect(model.rows.contains { $0.node?.entry.metadata.kind == .directory && $0.depth == 1 })
        await model.toggle(Data(folder.path.utf8))
        await model.toggle(Data(nested.path.utf8))
        #expect(model.rows.count == 6)
        let nestedFile: DiskTreeRow = try #require(model.rows.first { $0.node?.entry.path == Data(nested.appendingPathComponent("file-0").path.utf8) })
        let nestedRow: DiskTreeRow = try #require(model.rows.first { $0.node?.entry.path == Data(nested.path.utf8) })
        let folderRow: DiskTreeRow = try #require(model.rows.first { $0.node?.entry.path == Data(folder.path.utf8) })
        #expect(nestedFile.depth == 3)
        #expect(nestedFile.proportion == 1)
        #expect(abs(try #require(nestedRow.proportion) - 2.0 / 3.0) < 0.000_001)
        #expect(abs(try #require(folderRow.proportion) - 6.0 / 7.0) < 0.000_001)
        #expect(model.rows.first?.proportion == 1)
        await model.toggle(Data(folder.path.utf8))
        #expect(model.rows.count == 3)
        await model.toggle(Data(folder.path.utf8))
        #expect(model.rows.count == 6)
        #expect(Set(model.rows.map(\.id)).count == model.rows.count)
    }

    @Test func siblingPaginationIncludesFilesAndFoldersWithoutDuplicateRows() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        try treeFiles(directory: fixture.root, count: 500, bytes: 1)
        let folder: URL = fixture.root.appendingPathComponent("folder")
        try treeFiles(directory: folder, count: 1, bytes: 3)
        _ = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        #expect(model.rows.compactMap(\.node).count == 501)
        #expect(model.rows.contains { $0.id == .more(Data(fixture.root.path.utf8)) })
        await model.loadMore(Data(fixture.root.path.utf8))
        #expect(model.rows.count == 502)
        #expect(model.rows.compactMap(\.node).count == 502)
        #expect(Set(model.rows.map(\.id)).count == model.rows.count)
        #expect(model.rows.contains { $0.node?.entry.path == Data(folder.path.utf8) })
        #expect(model.rows.filter { $0.node?.entry.metadata.kind == .regularFile }.count == 500)
        #expect(!model.rows.contains { $0.id == .more(Data(fixture.root.path.utf8)) })
    }

    @Test(arguments: [0, 3])
    func expandedRowsRemainVisibleWhileRefreshReloadsTheSnapshot(addedFileCount: Int) async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        try treeFiles(directory: folder, count: 2, bytes: 4_096)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        await model.toggle(Data(folder.path.utf8))
        let selected: DiskTreeRowID = .node(Data(folder.appendingPathComponent("file-1").path.utf8))
        #expect(model.rows.contains { $0.id == selected })
        if addedFileCount > 0 {
            try treeFiles(directory: fixture.root, count: addedFileCount, bytes: 4_096)
            _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        }

        model.refresh()
        let deadline: Date = Date().addingTimeInterval(5)
        var missingSelection: Bool = false
        while model.isScanning && Date() < deadline {
            if !model.rows.contains(where: { $0.id == selected }) { missingSelection = true }
            await Task.yield()
        }
        try await waitForTreeScan(model)
        #expect(!missingSelection, "Reloading a scan temporarily removes the selected row from the native table")
        #expect(model.rows.contains { $0.id == selected })
        #expect(model.rows.count == 4 + addedFileCount)
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: [503, 510, 525])
    func refreshRetainsLoadedPagesAndTheirSelectableRows(refreshedFileCount: Int) async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        try treeFiles(directory: fixture.root, count: 510, bytes: 4_096)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        await model.loadMore(Data(fixture.root.path.utf8))
        let selected: DiskTreeRowID = try #require(model.rows.last).id
        #expect(model.rows.count == 511)
        if refreshedFileCount < 510 {
            for number: Int in refreshedFileCount..<510 {
                try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("file-\(number)"))
            }
        } else if refreshedFileCount > 510 {
            try treeFiles(directory: fixture.root, count: refreshedFileCount, bytes: 4_096)
        }
        if refreshedFileCount != 510 {
            _ = try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        }

        model.refresh()
        try await waitForTreeScan(model)
        #expect(model.rows.count == refreshedFileCount + 1)
        #expect(model.rows.contains { $0.id == selected }, "Refresh discarded the page containing the selected row")
        #expect(model.errorMessage == nil)
    }

    @Test func rawFilenameBytesRemainDistinctRowIdentities() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let paths: [Data] = [UInt8(0xfe), UInt8(0xff)].map { byte in Data(fixture.root.path.utf8) + Data([47, byte]) }
        try treeFiles(directory: fixture.root, count: 2, bytes: 3)
        _ = try await cachedTree(fixture: fixture)
        let connection: DatabaseQueue = try DatabaseQueue(path: fixture.cache.path)
        try await connection.write { db in
            for number: Int in paths.indices {
                try db.execute(sql: "UPDATE nodes SET path=?,name=? WHERE root=? AND path=?", arguments: [paths[number], Data([paths[number].last!]), fixture.root.path, Data(fixture.root.appendingPathComponent("file-\(number)").path.utf8)])
            }
        }
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        #expect(model.rows.count == 3)
        #expect(Set(model.rows.map(\.id)).count == 3)
        for path: Data in paths { #expect(model.rows.contains { $0.id == .node(path) }) }
        let files: [IndexedNode] = model.rows.compactMap(\.node).filter { $0.entry.metadata.kind == .regularFile }
        #expect(Set(files.map { String(decoding: $0.entry.name, as: UTF8.self) }).count == 1)
    }

    @Test func aliasAndCanonicalBranchesHaveDistinctVisiblePathsAndDrillDown() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let target: URL = fixture.root.appendingPathComponent("primary")
        let alias: URL = fixture.root.appendingPathComponent("alias")
        try treeFiles(directory: target.appendingPathComponent("nested"), count: 1, bytes: 8_192)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let summary: IndexSummary = try #require(try await index.cachedSummary(root: fixture.root.path))
        let connection: DatabaseQueue = try DatabaseQueue(path: fixture.cache.path)
        try await connection.write { db in
            try db.execute(sql: "INSERT INTO aliases(root,path,target,seen) VALUES(?,?,?,?)", arguments: [fixture.root.path, Data(alias.path.utf8), Data(target.path.utf8), summary.revision])
        }
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        await model.toggle(Data(alias.path.utf8))
        await model.toggle(Data(target.path.utf8))
        let aliasNested: URL = alias.appendingPathComponent("nested")
        let targetNested: URL = target.appendingPathComponent("nested")
        await model.toggle(Data(aliasNested.path.utf8))
        await model.toggle(Data(targetNested.path.utf8))
        #expect(model.rows.count == 7)
        #expect(Set(model.rows.map(\.id)).count == model.rows.count)
        #expect(model.rows.contains { $0.id == .node(Data(aliasNested.appendingPathComponent("file-0").path.utf8)) })
        #expect(model.rows.contains { $0.id == .node(Data(targetNested.appendingPathComponent("file-0").path.utf8)) })
        let aliasChild: DiskTreeRow = try #require(model.rows.first { $0.id == .node(Data(aliasNested.path.utf8)) })
        #expect(aliasChild.proportion == 1)
    }

    @Test func cachedRowsAppearBeforeQueuedScanAndRetargetIgnoresEarlierGeneration() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        try treeFiles(directory: fixture.root, count: 1, bytes: 3)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let previous: IndexSummary = try #require(try await index.cachedSummary(root: fixture.root.path))
        let other: URL = fixture.container.appendingPathComponent("other")
        try treeFiles(directory: other, count: 1, bytes: 7)
        _ = try await index.refresh(root: other.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        try treeFiles(directory: fixture.root.appendingPathComponent("new"), count: 600, bytes: 1)
        let entered: DispatchSemaphore = DispatchSemaphore(value: 0)
        let release: DispatchSemaphore = DispatchSemaphore(value: 0)
        let paused: Mutex<Bool> = Mutex(false)
        defer { release.signal() }
        let background: Task<IndexSummary, any Error> = Task.detached(priority: .utility) {
            try await index.refresh(root: fixture.root.path, mode: .full, receiveEvent: { event in
                guard case .batch = event else { return }
                let shouldPause: Bool = paused.withLock { state in
                    if state { return false }
                    state = true
                    return true
                }
                if shouldPause {
                    entered.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut { Issue.record("Timed out releasing model fixture scan") }
                }
            }, isCancelled: { false })
        }
        #expect(await waitForTreeSignal(entered, timeout: .now() + 2) == .success)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        #expect(model.isScanning)
        #expect(model.summary?.revision == previous.revision)
        #expect(model.summary?.logicalBytes == 3)
        #expect(model.rows.count == 2)
        await model.chooseRoot(other)
        #expect(model.rootPath == other.path)
        #expect(model.summary?.logicalBytes == 7)
        #expect(model.rows.count == 2)
        #expect(model.isScanning)
        release.signal()
        _ = try await background.value
        try await waitForTreeScan(model)
        #expect(model.rootPath == other.path)
        #expect(model.summary?.root == other.path)
        #expect(model.summary?.logicalBytes == 7)
        #expect(model.errorMessage == nil)
        #expect(!model.scanStopped)
        #expect(model.rows.allSatisfy { row in
            guard let node: IndexedNode = row.node else { return false }
            return node.entry.path == Data(other.path.utf8) || node.entry.path.starts(with: Data((other.path + "/").utf8))
        })
    }

    @Test func cancelledRefreshRetainsCommittedRowsAndReportsStoppedState() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        try treeFiles(directory: fixture.root, count: 1, bytes: 4_096)
        let index: DiskIndex = try await cachedTree(fixture: fixture)
        let previous: IndexSummary = try #require(try await index.cachedSummary(root: fixture.root.path))
        let added: URL = fixture.root.appendingPathComponent("new")
        try treeFiles(directory: added, count: 600, bytes: 1)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        model.cancelScan()
        try await waitForTreeScan(model)
        #expect(model.scanStopped)
        #expect(!model.isScanning)
        #expect(model.errorMessage == nil)
        #expect(model.summary == previous)
        #expect(model.rows.count == 2)
        #expect(!model.rows.contains { $0.id == .node(Data(added.path.utf8)) })
    }
}
