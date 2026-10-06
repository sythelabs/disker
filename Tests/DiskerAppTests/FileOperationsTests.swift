import AppKit
import Darwin
import DiskerCore
import Foundation
import Testing
@testable import Disker

private struct FileOperationFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
}

private func operationFixture() throws -> FileOperationFixture {
    let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-operations-" + UUID().uuidString).resolvingSymlinksInPath()
    let destination: URL = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    return FileOperationFixture(root: root, source: root.appendingPathComponent("source.txt"), destination: destination)
}

private func removeOperationFixture(_ fixture: FileOperationFixture) {
    do { try FileManager.default.removeItem(at: fixture.root) }
    catch { Issue.record(error) }
}

private func operationItem(path: Data, root: URL) throws -> FileItem {
    var entries: [ScanEntry] = []
    _ = try DirectoryScanner.scan(root: Data(root.path.utf8), options: ScanOptions(batchSize: 512, bufferSize: 256 * 1024, mountPolicy: .sameDevice, excludedPaths: []), isCancelled: { false }, receiveProgress: { _ in }, receiveBatch: { entries.append(contentsOf: $0) })
    return try FileItem(entry: #require(entries.first { $0.path == path }))
}

@Suite("File operations", .serialized)
@MainActor struct FileOperationsTests {
    @Test func trashSelectionValidatesEveryItemBeforeMovingAnyFile() async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("keep".utf8).write(to: fixture.source)
        let staleURL: URL = fixture.root.appendingPathComponent("stale.txt")
        try Data("original".utf8).write(to: staleURL)
        let items: [FileItem] = try [fixture.source, staleURL].map { try operationItem(path: filePathBytes($0), root: fixture.root) }
        try FileManager.default.moveItem(at: staleURL, to: fixture.root.appendingPathComponent("original.txt"))
        try Data("replacement".utf8).write(to: staleURL)
        await #expect(throws: FileOperationError.changedItem(items[1].id)) { try await FileOperations().trash(items) }
        #expect(try Data(contentsOf: fixture.source) == Data("keep".utf8))
        #expect(try Data(contentsOf: staleURL) == Data("replacement".utf8))
    }

    @Test func emptyTrashSelectionIsRejected() async throws {
        await #expect(throws: FileOperationError.emptySelection) { try await FileOperations().trash([]) }
    }

    @Test(arguments: [false, true])
    func trashSelectionMovesFilesAndFoldersWithoutSubmittingDescendantsTwice(childFirst: Bool) async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        let folder: URL = fixture.root.appendingPathComponent("folder")
        let neighbor: URL = fixture.root.appendingPathComponent("folder-other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child: URL = folder.appendingPathComponent("child.txt")
        try Data("child".utf8).write(to: child)
        try Data("neighbor".utf8).write(to: neighbor)
        try Data("file".utf8).write(to: fixture.source)
        let paths: [URL] = childFirst ? [child, folder, fixture.source, neighbor, folder] : [folder, child, folder, neighbor, fixture.source]
        let items: [FileItem] = try paths.map { try operationItem(path: filePathBytes($0), root: fixture.root) }
        let results: [URL: URL] = try await FileOperations().trash(items)
        defer {
            for destination: URL in results.values {
                do { try FileManager.default.removeItem(at: destination) }
                catch { Issue.record(error) }
            }
        }
        #expect(Set(results.keys) == Set([folder, neighbor, fixture.source]))
        for source: URL in [folder, child, neighbor, fixture.source] { #expect(!FileManager.default.fileExists(atPath: source.path)) }
        let trashedFolder: URL = try #require(results[folder])
        #expect(try Data(contentsOf: trashedFolder.appendingPathComponent("child.txt")) == Data("child".utf8))
        #expect(try Data(contentsOf: #require(results[neighbor])) == Data("neighbor".utf8))
        #expect(try Data(contentsOf: #require(results[fixture.source])) == Data("file".utf8))
    }

    @Test func multipleSelectionCopiesAllURLsAndEmptySelectionPreservesClipboard() throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("first".utf8).write(to: fixture.source)
        let second: URL = fixture.root.appendingPathComponent("second.txt")
        try Data("second".utf8).write(to: second)
        let items: [FileItem] = try [fixture.source, second].map { try operationItem(path: filePathBytes($0), root: fixture.root) }
        let pasteboard: NSPasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let operations: FileOperations = FileOperations()
        try operations.copy(items, to: pasteboard)
        #expect(try operations.files(on: pasteboard) == [fixture.source, second])
        #expect(throws: FileOperationError.emptySelection) { try operations.copy([], to: pasteboard) }
        #expect(try operations.files(on: pasteboard) == [fixture.source, second])
    }

    @Test func renamePreservesContentsAndRefusesToOverwriteAnotherFile() async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("original".utf8).write(to: fixture.source)
        let item: FileItem = try operationItem(path: Data(fixture.source.path.utf8), root: fixture.root)
        let operations: FileOperations = FileOperations()
        let renamed: URL = try await operations.rename(item, to: "renamed.txt")
        #expect(try Data(contentsOf: renamed) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        let other: URL = fixture.root.appendingPathComponent("other.txt")
        try Data("keep".utf8).write(to: other)
        let current: FileItem = try operationItem(path: Data(renamed.path.utf8), root: fixture.root)
        await #expect(throws: FileOperationError.self) { try await operations.rename(current, to: "other.txt") }
        #expect(try Data(contentsOf: other) == Data("keep".utf8))
        #expect(try Data(contentsOf: renamed) == Data("original".utf8))
    }

    @Test(arguments: ["", ".", "..", "nested/file", "null\0name"])
    func invalidNamesNeverMoveTheSource(name: String) async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("original".utf8).write(to: fixture.source)
        let item: FileItem = try operationItem(path: Data(fixture.source.path.utf8), root: fixture.root)
        await #expect(throws: FileOperationError.invalidName(name)) { try await FileOperations().rename(item, to: name) }
        #expect(try Data(contentsOf: fixture.source) == Data("original".utf8))
    }

    @Test func staleRowsCannotRenameReplacementFiles() async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("original".utf8).write(to: fixture.source)
        let item: FileItem = try operationItem(path: Data(fixture.source.path.utf8), root: fixture.root)
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("original.txt"))
        try Data("replacement".utf8).write(to: fixture.source)
        await #expect(throws: FileOperationError.changedItem(item.id)) { try await FileOperations().rename(item, to: "renamed.txt") }
        #expect(try Data(contentsOf: fixture.source) == Data("replacement".utf8))
    }

    @Test func pasteCopiesAndMoveTransfersWithoutReplacingExistingFiles() async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("original".utf8).write(to: fixture.source)
        let operations: FileOperations = FileOperations()
        let pasted: URL = try await operations.paste(fixture.source, into: fixture.destination)
        #expect(try Data(contentsOf: pasted) == Data("original".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        await #expect(throws: FileOperationError.self) { try await operations.move(fixture.source, into: fixture.destination) }
        try FileManager.default.removeItem(at: pasted)
        let moved: URL = try await operations.move(fixture.source, into: fixture.destination)
        #expect(try Data(contentsOf: moved) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test func foldersCannotBeMovedOrCopiedIntoThemselves() async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        let operations: FileOperations = FileOperations()
        await #expect(throws: FileOperationError.self) { try await operations.move(fixture.root, into: fixture.destination) }
        await #expect(throws: FileOperationError.self) { try await operations.paste(fixture.root, into: fixture.destination) }
        #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func rawFilenameBytesSurviveURLsClipboardAndPaste() async throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        let name: Data = Data([0x66, 0xc3, 0xa9, 0x0a, 0x25, 0x20])
        let path: Data = Data(fixture.root.path.utf8) + Data([47]) + name
        let bytes: [UInt8] = Array(path) + [0]
        let descriptor: Int32 = bytes.withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw ScanError.systemCall(path: path, operation: "create fixture", errnoCode: errno) }
        guard close(descriptor) == 0 else { throw ScanError.systemCall(path: path, operation: "close fixture", errnoCode: errno) }
        let item: FileItem = try operationItem(path: path, root: fixture.root)
        #expect(try filePathBytes(item.url) == path)
        let pasteboard: NSPasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let operations: FileOperations = FileOperations()
        try operations.copy(item, to: pasteboard)
        let copied: URL = try #require(try operations.files(on: pasteboard).first)
        let copiedPath: Data = try filePathBytes(copied)
        #expect(copiedPath == path, "Clipboard URL: \(copied.absoluteString); actual bytes: \(Array(copiedPath)); expected bytes: \(Array(path))")
        let pasted: URL = try await operations.paste(copied, into: fixture.destination)
        let pastedPath: Data = try filePathBytes(pasted)
        #expect(pastedPath == Data(fixture.destination.path.utf8) + Data([47]) + name)
        #expect(try filePathBytes(item.url) == path)
    }

    @Test func invalidUTF8CachedNamesRemainDistinctInURLsAndClipboard() throws {
        let fixture: FileOperationFixture = try operationFixture()
        defer { removeOperationFixture(fixture) }
        try Data("original".utf8).write(to: fixture.source)
        let metadata: FileMetadata = try operationItem(path: Data(fixture.source.path.utf8), root: fixture.root).entry.metadata
        let pasteboard: NSPasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for byte: UInt8 in [0xfe, 0xff] {
            let path: Data = Data(fixture.root.path.utf8) + Data([47, byte])
            let item: FileItem = try FileItem(entry: ScanEntry(path: path, parentPath: Data(fixture.root.path.utf8), name: Data([byte]), metadata: metadata))
            let actualPath: Data = try filePathBytes(item.url)
            #expect(actualPath == path, "URL: \(item.url.absoluteString); actual bytes: \(Array(actualPath)); expected bytes: \(Array(path))")
            try FileOperations().copy(item, to: pasteboard)
            let copied: URL = try #require(try FileOperations().files(on: pasteboard).first)
            #expect(try filePathBytes(copied) == path)
        }
    }
}
