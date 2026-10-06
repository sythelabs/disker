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

private enum TreePreviewReplay: CaseIterable, Sendable {
    case branch
    case rootDirectory
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
    @Test(arguments: [(0, 1), (0, 510), (510, 510)])
    func foldersExpandBeforeTheInitialScanCommits(rootFileCount: Int, folderFileCount: Int) async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        let nested: URL = folder.appendingPathComponent("nested")
        try treeFiles(directory: folder, count: folderFileCount, bytes: 4_096)
        try treeFiles(directory: nested, count: 1, bytes: 8_192)
        try treeFiles(directory: fixture.root.appendingPathComponent("padding"), count: 600, bytes: 1)
        try treeFiles(directory: fixture.root, count: rootFileCount, bytes: 1)
        let release: DispatchSemaphore = DispatchSemaphore(value: 0)
        let paused: Mutex<Bool> = Mutex(false)
        defer { release.signal() }
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache, receiveScanEvent: { event in
            guard case .batch = event else { return }
            let shouldPause: Bool = paused.withLock { state in
                if state { return false }
                state = true
                return true
            }
            if shouldPause, release.wait(timeout: .now() + 10) == .timedOut {
                Issue.record("Timed out releasing initial tree scan")
            }
        })
        await model.start()
        let folderPath: Data = Data(folder.path.utf8)
        let nestedPath: Data = Data(nested.path.utf8)
        let rootPath: Data = Data(fixture.root.path.utf8)
        let deadline: Date = Date().addingTimeInterval(5)
        while model.rows.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.rows.isEmpty)
        if rootFileCount > 500 {
            #expect(model.rows.contains { $0.id == .more(rootPath) })
            await model.loadMore(rootPath)
            #expect(model.rows.filter { $0.node?.entry.parentPath == rootPath }.count == rootFileCount + 2)
        }
        try #require(model.rows.contains { $0.id == .node(folderPath) })
        #expect(model.isScanning)
        #expect(model.summary == nil)
        await model.toggle(folderPath)
        #expect(model.expanded.contains(folderPath))
        #expect(model.rows.contains { $0.id == .node(Data(folder.appendingPathComponent("file-0").path.utf8)) }, "Expanding a visible folder during the initial scan shows no children")
        #expect(model.rows.filter { $0.node?.entry.parentPath == folderPath }.count == min(500, folderFileCount + 1))
        if folderFileCount > 500 {
            #expect(model.rows.contains { $0.id == .more(folderPath) })
            await model.loadMore(folderPath)
            #expect(model.rows.filter { $0.node?.entry.parentPath == folderPath }.count == folderFileCount + 1)
            #expect(!model.rows.contains { $0.id == .more(folderPath) })
        }
        #expect(model.rows.contains { $0.id == .node(nestedPath) })
        await model.toggle(nestedPath)
        let nestedFile: DiskTreeRowID = .node(Data(nested.appendingPathComponent("file-0").path.utf8))
        #expect(model.rows.contains { $0.id == nestedFile })
        #expect(model.summary == nil)
        let visibleIDs: [DiskTreeRowID] = model.rows.map(\.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.rows.map(\.id) == visibleIDs, "Scan preview updates must retain expanded branches and loaded pages")
        #expect(Set(visibleIDs).count == visibleIDs.count)
        await model.toggle(folderPath)
        #expect(!model.rows.contains { $0.id == nestedFile })
        await model.toggle(folderPath)
        if folderFileCount > 500 { await model.loadMore(folderPath) }
        #expect(model.rows.contains { $0.id == nestedFile })
        release.signal()
        try await waitForTreeScan(model)
        #expect(model.rows.contains { $0.id == nestedFile })
        #expect(model.errorMessage == nil)
    }

    @Test func columnSortingPreservesExpandedHierarchyAndRefreshOrder() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder2: URL = fixture.root.appendingPathComponent("folder2")
        let folder10: URL = fixture.root.appendingPathComponent("folder10")
        try treeFiles(directory: folder2, count: 12, bytes: 1)
        try treeFiles(directory: folder10, count: 1, bytes: 65_536)
        _ = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        await model.toggle(Data(folder2.path.utf8))
        await model.toggle(Data(folder10.path.utf8))
        let ids: Set<DiskTreeRowID> = Set(model.rows.map(\.id))
        model.sortOrder = [DiskTreeSort(sort: NodeSort(column: .name, order: .forward))]
        await model.sort()
        #expect(model.rows.filter { $0.depth == 1 }.compactMap { $0.node.map { String(decoding: $0.entry.name, as: UTF8.self) } } == ["folder2", "folder10"])
        let firstBranch: [DiskTreeRow] = Array(model.rows[2..<14])
        #expect(firstBranch.allSatisfy { $0.node?.entry.parentPath == Data(folder2.path.utf8) && $0.depth == 2 })
        #expect(firstBranch.compactMap { $0.node.map { String(decoding: $0.entry.name, as: UTF8.self) } } == (0..<12).map { "file-\($0)" })
        #expect(Set(model.rows.map(\.id)) == ids)

        model.sortOrder[0].order = .reverse
        await model.sort()
        #expect(model.rows[1].id == .node(Data(folder10.path.utf8)))
        #expect(model.rows[2].node?.entry.parentPath == Data(folder10.path.utf8))
        #expect(model.rows[3].id == .node(Data(folder2.path.utf8)))
        #expect(model.rows[4].node?.entry.name == Data("file-11".utf8))
        model.refresh()
        try await waitForTreeScan(model)
        #expect(model.rows[1].id == .node(Data(folder10.path.utf8)))
        #expect(Set(model.rows.map(\.id)) == ids)
        #expect(model.errorMessage == nil)
    }

    @Test func changingSortDuringPaginationDoesNotMixPageOrders() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        try treeFiles(directory: fixture.root, count: 600, bytes: 1)
        _ = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        model.sortOrder = [DiskTreeSort(sort: NodeSort(column: .name, order: .forward))]
        await model.sort()
        #expect(model.rows[1].node?.entry.name == Data("file-0".utf8))
        #expect(model.rows[500].node?.entry.name == Data("file-499".utf8))
        #expect(model.rows.last?.id == .more(Data(fixture.root.path.utf8)))

        let pending: Task<Void, Never> = Task { await model.loadMore(Data(fixture.root.path.utf8)) }
        await Task.yield()
        model.sortOrder[0].order = .reverse
        await model.sort()
        await pending.value
        await model.loadMore(Data(fixture.root.path.utf8))
        let names: [String] = model.rows.dropFirst().compactMap { $0.node.map { String(decoding: $0.entry.name, as: UTF8.self) } }
        #expect(names == (0..<600).reversed().map { "file-\($0)" })
        #expect(Set(model.rows.map(\.id)).count == 601)
        #expect(model.errorMessage == nil)
    }

    @Test func scanProgressFinishesAndResetsOnRefresh() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        try treeFiles(directory: fixture.root.appendingPathComponent("folder/nested"), count: 3, bytes: 1)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        #expect(model.scanProgress == 0)
        await model.start()
        #expect(model.isScanning)
        #expect(model.scanProgress == 0)
        try await waitForTreeScan(model)
        #expect(model.errorMessage == nil)
        #expect(model.scanProgress == 1)
        #expect(!model.isScanning)

        model.refresh()
        #expect(model.isScanning)
        #expect(model.scanProgress == 0)
        try await waitForTreeScan(model)
        #expect(model.errorMessage == nil)
        #expect(model.scanProgress == 1)
        #expect(!model.isScanning)
    }

    @Test func fileOperationRefreshUpdatesExpandedBranchesImmediately() async throws {
        let fixture: TreeFixture = try treeFixture()
        defer { removeTreeFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        try treeFiles(directory: folder, count: 1, bytes: 4_096)
        _ = try await cachedTree(fixture: fixture)
        let model: DiskTreeModel = DiskTreeModel(rootURL: fixture.root, cacheURL: fixture.cache)
        await model.start()
        try await waitForTreeScan(model)
        await model.toggle(Data(folder.path.utf8))
        let old: URL = folder.appendingPathComponent("file-0")
        let renamed: URL = folder.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: old, to: renamed)
        await model.refreshDirectories([Data(folder.path.utf8)])
        #expect(!model.isScanning)
        #expect(model.errorMessage == nil)
        #expect(!model.rows.contains { $0.id == .node(Data(old.path.utf8)) })
        #expect(model.rows.contains { $0.id == .node(Data(renamed.path.utf8)) })
        #expect(model.expanded.contains(Data(folder.path.utf8)))
    }

    @Test(arguments: TreePreviewReplay.allCases)
    fileprivate func repeatedPreviewScopeDoesNotCountFilesTwice(replay: TreePreviewReplay) async throws {
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
        switch replay {
        case .branch:
            let scope: ScanEntry = ScanEntry(path: folderEntry.path, parentPath: nil, name: folderEntry.name, metadata: folderEntry.metadata)
            buffer.receive(.batch([scope, fileEntry]))
        case .rootDirectory:
            buffer.receive(.batch([rootEntry, folderEntry]))
        }
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
        let sorted: TreeScanPreview = try after.sorted(using: NodeSort(column: .allocatedSize, order: .reverse))
        #expect(sorted.nodes.map(\.entry.path) == [second.path, first.path])
        #expect(sorted.totals.allocated == after.totals.allocated)
        #expect(buffer.snapshot().nodes.map(\.entry.path) == before)
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
        let selected: DiskTreeRowID = .node(Data(fixture.root.appendingPathComponent("file-500").path.utf8))
        #expect(model.rows.contains { $0.id == selected })
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
        #expect(model.scanProgress == 0)
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
        #expect(model.scanProgress < 1)
        #expect(model.errorMessage == nil)
        #expect(model.summary == previous)
        #expect(model.rows.count == 2)
        #expect(!model.rows.contains { $0.id == .node(Data(added.path.utf8)) })
    }
}
