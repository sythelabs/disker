import Foundation
import GRDB
import Testing
@testable import DiskerCore

private func runFixtureGit(_ arguments: [String], at root: URL) throws {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let pipe: Pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output: Data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitInspectionError.commandFailed(executable: "/usr/bin/git", arguments: arguments, status: process.terminationStatus, stderr: String(decoding: output, as: UTF8.self))
    }
}

@Suite(.serialized)
struct GitCacheTests {
    @Test(arguments: [FileKind.directory, .regularFile])
    func gitEnrichmentPersistsAndInvalidatesAfterFilesystemRefresh(linkCountKind: FileKind) async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root: URL = fixture.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try runFixtureGit(["init", "-q"], at: root)
        try runFixtureGit(["config", "user.name", "Disker Tests"], at: root)
        try runFixtureGit(["config", "user.email", "tests@example.test"], at: root)
        let file: URL = root.appendingPathComponent("file")
        try Data("clean".utf8).write(to: file)
        try runFixtureGit(["add", "file"], at: root)
        try runFixtureGit(["commit", "-qm", "fixture"], at: root)
        let cache: URL = fixture.appendingPathComponent("cache/index.sqlite")
        let index: DiskIndex = try DiskIndex(databaseURL: cache)
        _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let first: CachedGitInfo = try #require(try await index.gitInfo(root: root.path, path: root.path, inspector: inspector))
        #expect(!first.wasCached)
        #expect(!first.info.isDirty)
        let reopened: DiskIndex = try DiskIndex(databaseURL: cache)
        let persisted: CachedGitInfo = try #require(try await reopened.gitInfo(root: root.path, path: root.path, inspector: inspector))
        #expect(persisted.wasCached)
        let connection: DatabaseQueue = try DatabaseQueue(path: cache.path)
        let metadataPath: Data = Data((linkCountKind == .directory ? root.appendingPathComponent(".git/objects") : file).path.utf8)
        try await connection.write { db in
            var metadata: Data = try #require(try Data.fetchOne(db, sql: "SELECT metadata FROM nodes WHERE path=?", arguments: [metadataPath]))
            var differentLinkCount: UInt64 = UInt64(try decodeMetadata(metadata).linkCount + 1).littleEndian
            withUnsafeBytes(of: &differentLinkCount) { metadata.replaceSubrange(24..<32, with: $0) }
            try db.execute(sql: "UPDATE nodes SET metadata=? WHERE path=?", arguments: [metadata, metadataPath])
        }
        _ = try await reopened.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let unchanged: CachedGitInfo = try #require(try await reopened.gitInfo(root: root.path, path: root.path, inspector: inspector))
        #expect(unchanged.wasCached == (linkCountKind == .directory), "Directory link counts may vary between APFS metadata queries; file link changes still invalidate the cache")
        try Data("changed source without changing HEAD or index".utf8).write(to: file)
        _ = try await reopened.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
        let edited: CachedGitInfo = try #require(try await reopened.gitInfo(root: root.path, path: root.path, inspector: inspector))
        #expect(!edited.wasCached)
        #expect(edited.info.isDirty)
    }
}
