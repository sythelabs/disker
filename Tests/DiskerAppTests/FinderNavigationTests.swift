import DiskerCore
import Foundation
import Testing
@testable import Disker

private enum FinderNavigationTestError: Error {
    case scanTimedOut
}

private func finderSearchRow(path: Data, parent: Data?, name: Data, kind: FileKind, depth: Int) -> DiskTreeRow {
    let timestamp: FileTimestamp = FileTimestamp(seconds: 0, nanoseconds: 0)
    let metadata: FileMetadata = FileMetadata(kind: kind, device: 1, inode: 1, linkCount: 1, mode: 0, ownerID: 0, groupID: 0, logicalBytes: 1, allocatedBytes: 1, birthTime: timestamp, modificationTime: timestamp, changeTime: timestamp, accessTime: timestamp, flags: 0)
    let entry: ScanEntry = ScanEntry(path: path, parentPath: parent, name: name, metadata: metadata)
    return .node(IndexedNode(entry: entry, subtreeLogicalBytes: 1, subtreeAllocatedBytes: 1, subtreeNodeCount: 1, aliasTargetPath: nil), depth: depth, parentBytes: 1)
}

@Suite("Finder navigation")
struct FinderNavigationTests {
    @Test @MainActor func navigationHistorySupportsBoundariesDuplicatesAndBranching() async throws {
        let container: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-navigation-" + UUID().uuidString).resolvingSymlinksInPath()
        defer {
            do { try FileManager.default.removeItem(at: container) }
            catch { Issue.record(error) }
        }
        let roots: [URL] = ["first", "second", "third"].map { container.appendingPathComponent($0) }
        let cache: URL = container.appendingPathComponent("cache/index.sqlite")
        let index: DiskIndex = try DiskIndex(databaseURL: cache)
        for root: URL in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data([1]).write(to: root.appendingPathComponent("file"))
            _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        }
        let model: DiskTreeModel = DiskTreeModel(rootURL: roots[0], cacheURL: cache)
        await model.start()
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
        await model.chooseRoot(roots[1])
        await model.chooseRoot(roots[2])
        #expect(model.canGoBack)
        #expect(!model.canGoForward)
        await model.goBack()
        #expect(model.rootPath == roots[1].path)
        #expect(model.summary?.root == roots[1].path)
        #expect(model.canGoForward)
        await model.chooseRoot(roots[1].appendingPathComponent("."))
        model.refresh()
        #expect(model.canGoForward)
        await model.goBack()
        #expect(model.rootPath == roots[0].path)
        #expect(!model.canGoBack)
        await model.goBack()
        #expect(model.rootPath == roots[0].path)
        await model.goForward()
        #expect(model.rootPath == roots[1].path)
        await model.goForward()
        #expect(model.rootPath == roots[2].path)
        #expect(!model.canGoForward)
        await model.goForward()
        #expect(model.rootPath == roots[2].path)
        await model.goBack()
        await model.chooseRoot(roots[0])
        #expect(model.rootPath == roots[0].path)
        #expect(!model.canGoForward)
        await model.goBack()
        #expect(model.rootPath == roots[1].path)
        #expect(model.errorMessage == nil)
        model.cancelScan()
        let deadline: Date = Date().addingTimeInterval(5)
        while model.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if model.isScanning { throw FinderNavigationTestError.scanTimedOut }
    }

    @Test func searchKeepsMatchingItemsWithTheirFolderContext() {
        let root: Data = Data("/root".utf8)
        let folder: Data = Data("/root/documents".utf8)
        let report: Data = Data("/root/documents/Report.pdf".utf8)
        let other: Data = Data("/root/documents/Other.pdf".utf8)
        let rows: [DiskTreeRow] = [
            finderSearchRow(path: root, parent: nil, name: Data("root".utf8), kind: .directory, depth: 0),
            finderSearchRow(path: folder, parent: root, name: Data("documents".utf8), kind: .directory, depth: 1),
            finderSearchRow(path: report, parent: folder, name: Data("Report.pdf".utf8), kind: .regularFile, depth: 2),
            finderSearchRow(path: other, parent: folder, name: Data("Other.pdf".utf8), kind: .regularFile, depth: 2),
            .more(folder, depth: 2)
        ]
        #expect(searchTreeRows(rows, query: "  REPORT  ").map(\.id) == [.node(root), .node(folder), .node(report)])
        #expect(searchTreeRows(rows, query: "documents").map(\.id) == [.node(root), .node(folder)])
        #expect(searchTreeRows(rows, query: "missing").isEmpty)
        #expect(searchTreeRows(rows, query: " \n ").map(\.id) == rows.map(\.id))
    }

    @Test func searchPreservesDistinctRawFilenameIdentities() {
        let root: Data = Data("/root".utf8)
        let names: [Data] = [Data("report".utf8) + Data([0xfe]), Data("report".utf8) + Data([0xff])]
        let rows: [DiskTreeRow] = [finderSearchRow(path: root, parent: nil, name: Data("root".utf8), kind: .directory, depth: 0)] + names.map { name in
            finderSearchRow(path: root + Data([47]) + name, parent: root, name: name, kind: .regularFile, depth: 1)
        }
        #expect(searchTreeRows(rows, query: "report").map(\.id) == rows.map(\.id))
    }
}
