import Foundation
import GRDB
import Testing
@testable import DiskerCore

@Test func cachedAliasesPermitDrilldownWithoutDuplicatingTotals() async throws {
    let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root: URL = fixture.appendingPathComponent("root")
    let target: URL = root.appendingPathComponent("primary")
    let alias: URL = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: target.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    try Data(repeating: 1, count: 17).write(to: target.appendingPathComponent("nested/file"))
    let cache: URL = fixture.appendingPathComponent("cache/index.sqlite")
    let index: DiskIndex = try DiskIndex(databaseURL: cache)
    let initial: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
    let connection: DatabaseQueue = try DatabaseQueue(path: cache.path)
    try await connection.write { db in
        try db.execute(sql: "INSERT INTO aliases(root,path,target,seen) VALUES(?,?,?,?)", arguments: [root.path, Data(alias.path.utf8), Data(target.path.utf8), initial.revision])
    }
    let aliasNode: IndexedNode = try #require(try await index.node(root: root.path, path: Data(alias.path.utf8)))
    #expect(aliasNode.entry.path == Data(alias.path.utf8))
    #expect(aliasNode.aliasTargetPath == Data(target.path.utf8))
    let children: [IndexedNode] = try await index.children(root: root.path, directory: Data(alias.path.utf8), offset: 0, limit: 10)
    #expect(children.count == 1)
    #expect(children.first?.subtreeLogicalBytes == 17)
    let nested: [IndexedNode] = try await index.children(root: root.path, directory: Data(alias.appendingPathComponent("nested").path.utf8), offset: 0, limit: 10)
    #expect(nested.first?.entry.metadata.logicalBytes == 17)
    #expect(try await index.node(root: root.path, path: Data(alias.appendingPathComponent("nested/file").path.utf8))?.entry.metadata.logicalBytes == 17)
    #expect(try await index.cachedSummary(root: root.path)?.logicalBytes == 17)
    _ = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
    #expect(try await index.children(root: root.path, directory: Data(alias.path.utf8), offset: 0, limit: 10).isEmpty)
}

private enum AliasFixtureError: Error {
    case journalDidNotSettle(String)
}

@Test(arguments: ["alias", "primary"])
func replacingAliasedDirectoryWithFileRemovesObsoleteAliases(replacementName: String) async throws {
    let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-alias-" + UUID().uuidString)
    let root: URL = fixture.appendingPathComponent("root")
    let target: URL = root.appendingPathComponent("primary")
    let alias: URL = root.appendingPathComponent("alias")
    let untouched: URL = root.appendingPathComponent("untouched")
    try FileManager.default.createDirectory(at: target.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alias.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: untouched, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: fixture) }
        catch { Issue.record("Could not remove alias fixture: \(error)") }
    }
    try Data(repeating: 1, count: 17).write(to: target.appendingPathComponent("nested/file"))
    for number: Int in 0..<600 {
        try Data([1]).write(to: untouched.appendingPathComponent("file-\(number)"))
    }
    let cache: URL = fixture.appendingPathComponent("cache/index.sqlite")
    let index: DiskIndex = try DiskIndex(databaseURL: cache)
    let initial: IndexSummary = try await index.refresh(root: root.path, mode: .full, receiveEvent: { _ in }, isCancelled: { false })
    let deadline: Date = Date().addingTimeInterval(5)
    var settled: Bool = false
    while Date() < deadline {
        let quiet: IndexSummary = try await index.refresh(root: root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
        if quiet.metrics.entries == 0 { settled = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard settled else { throw AliasFixtureError.journalDidNotSettle(root.path) }
    let connection: DatabaseQueue = try DatabaseQueue(path: cache.path)
    try await connection.write { db in
        for suffix: String in ["", "/nested"] {
            try db.execute(sql: "INSERT INTO aliases(root,path,target,seen) VALUES(?,?,?,?)", arguments: [root.path, Data((alias.path + suffix).utf8), Data((target.path + suffix).utf8), initial.revision])
        }
    }
    let journal: FileEventJournal = try FileEventJournal(rootPath: root.path, checkpoint: nil, latency: 0.01)
    defer { journal.stop() }
    let before: JournalReplay = try journal.replay(timeout: 5, isCancelled: { false })
    let replaced: URL = root.appendingPathComponent(replacementName)
    try FileManager.default.removeItem(at: replaced)
    try Data(repeating: 2, count: 3).write(to: replaced)
    let eventDeadline: Date = Date().addingTimeInterval(5)
    var delivered: Bool = false
    while Date() < eventDeadline {
        let update: JournalReplay = try journal.drain()
        let advanced: Bool = (update.checkpoint?.eventID ?? 0) > (before.checkpoint?.eventID ?? 0)
        if advanced && (update.dirtyDirectories.contains(root.path) || update.recursiveDirectories.contains(root.path) || update.requiresFullScan) {
            delivered = true
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard delivered else { throw AliasFixtureError.journalDidNotSettle(root.path) }
    let refreshed: IndexSummary = try await index.refresh(root: root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { false })
    #expect(refreshed.metrics.entries < initial.metrics.entries / 4)
    #expect(refreshed.logicalBytes == (replacementName == "alias" ? 620 : 603))
    let remainingAliases: Int = try await connection.read { db in
        try #require(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM aliases WHERE root=?", arguments: [root.path]))
    }
    #expect(remainingAliases == 0)
    let replacement: IndexedNode = try #require(try await index.node(root: root.path, path: Data(replaced.path.utf8)))
    #expect(replacement.entry.path == Data(replaced.path.utf8))
    #expect(replacement.entry.metadata.kind == .regularFile)
    #expect(replacement.entry.metadata.logicalBytes == 3)
    #expect(replacement.aliasTargetPath == nil)
    #expect(try await index.node(root: root.path, path: Data(alias.appendingPathComponent("nested/file").path.utf8)) == nil)
    #expect(try await index.children(root: root.path, directory: Data(replaced.path.utf8), offset: 0, limit: 10).isEmpty)
}
