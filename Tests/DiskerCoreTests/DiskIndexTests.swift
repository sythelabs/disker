import Darwin
import Foundation
import Testing
@testable import DiskerCore

@Suite(.serialized)
struct DiskIndexTests {
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
