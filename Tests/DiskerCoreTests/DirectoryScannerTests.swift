import CDiskerScan
import Darwin
import Foundation
import Testing
@testable import DiskerCore

private func fixtureDirectory() throws -> URL {
    let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("disker-scanner-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func scanOptions(excludedPaths: [Data]) -> ScanOptions {
    ScanOptions(batchSize: 2, bufferSize: 4096, mountPolicy: .crossDevices, excludedPaths: excludedPaths)
}

private func collectScan(root: URL) throws -> (entries: [ScanEntry], summary: ScanSummary) {
    var entries: [ScanEntry] = []
    let summary: ScanSummary = try DirectoryScanner.scan(
        root: Data(root.path.utf8), options: scanOptions(excludedPaths: []), isCancelled: { false }
    ) { batch in
        entries.append(contentsOf: batch)
    }
    return (entries, summary)
}

@Test func recursiveScanStreamsMetadataWithoutReadingContent() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let child: URL = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    try Data(repeating: 0x61, count: 37).write(to: child.appendingPathComponent("file"))
    try Data().write(to: root.appendingPathComponent("empty"))
    var entries: [ScanEntry] = []
    var batchCounts: [Int] = []
    let summary: ScanSummary = try DirectoryScanner.scan(
        root: Data(root.path.utf8), options: scanOptions(excludedPaths: []), isCancelled: { false }
    ) { batch in
        batchCounts.append(batch.count)
        entries.append(contentsOf: batch)
    }
    #expect(entries.count == 4)
    #expect(entries.first?.parentPath == nil)
    #expect(entries.first?.metadata.kind == .directory)
    #expect(entries.first(where: { $0.name == Data("file".utf8) })?.metadata.logicalBytes == 37)
    #expect(entries.first(where: { $0.name == Data("file".utf8) })?.parentPath == Data(child.path.utf8))
    #expect(batchCounts.allSatisfy { $0 <= 2 })
    #expect(summary.metrics.entries == 4)
    #expect(summary.metrics.directories == 2)
    #expect(summary.metrics.bulkCalls > 0)
    #expect(summary.metrics.contentBytesRead == 0)
    #expect(summary.issues.isEmpty)
    #expect(summary.aliases.isEmpty)
}

@Test func symbolicLinksAreEntriesAndNeverDescended() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("broken").path, withDestinationPath: "missing")
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    #expect(result.entries.count == 3)
    #expect(result.entries.filter { $0.metadata.kind == .symbolicLink }.count == 2)
    #expect(result.summary.metrics.directories == 1)
    #expect(result.summary.issues.isEmpty)
}

@Test func hardLinksKeepDistinctPathsAndSharedFileIdentity() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first: URL = root.appendingPathComponent("first")
    try Data(repeating: 0x31, count: 17).write(to: first)
    try FileManager.default.linkItem(at: first, to: root.appendingPathComponent("second"))
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    let files: [ScanEntry] = result.entries.filter { $0.metadata.kind == .regularFile }
    #expect(files.count == 2)
    #expect(files[0].path != files[1].path)
    #expect(files[0].metadata.device == files[1].metadata.device)
    #expect(files[0].metadata.inode == files[1].metadata.inode)
    #expect(files.allSatisfy { $0.metadata.linkCount == 2 })
}

@Test func sparseFilesSeparateLogicalAndAllocatedSize() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path: String = root.appendingPathComponent("sparse").path
    let descriptor: Int32 = open(path, O_CREAT | O_WRONLY | O_EXCL, mode_t(0o600))
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    defer { _ = close(descriptor) }
    #expect(ftruncate(descriptor, 64 * 1024 * 1024) == 0)
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    let sparse: ScanEntry = try #require(result.entries.first(where: { $0.name == Data("sparse".utf8) }))
    #expect(sparse.metadata.logicalBytes == 64 * 1024 * 1024)
    #expect(sparse.metadata.allocatedBytes < sparse.metadata.logicalBytes)
    #expect(result.summary.metrics.contentBytesRead == 0)
}

@Test func directoryEnumerationDoesNotDescendAndExclusionsAreReported() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let child: URL = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    try Data([1]).write(to: child.appendingPathComponent("nested"))
    var entries: [ScanEntry] = []
    let direct: ScanSummary = try DirectoryScanner.enumerateDirectory(
        path: Data(root.path.utf8), options: scanOptions(excludedPaths: []), isCancelled: { false }
    ) { entries.append(contentsOf: $0) }
    #expect(entries.count == 2)
    #expect(direct.metrics.directories == 1)
    #expect(direct.aliases.isEmpty)
    entries.removeAll()
    let excluded: ScanSummary = try DirectoryScanner.scan(
        root: Data(root.path.utf8), options: scanOptions(excludedPaths: [Data(child.path.utf8)]), isCancelled: { false }
    ) { entries.append(contentsOf: $0) }
    #expect(entries.count == 1)
    #expect(excluded.issues.contains { $0.kind == .excluded && $0.path == Data(child.path.utf8) })
}

@Test func scannerCancellationIsExplicit() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ScanError.cancelled) {
        try DirectoryScanner.scan(
            root: Data(root.path.utf8), options: scanOptions(excludedPaths: []), isCancelled: { true }
        ) { _ in Issue.record("Cancelled scan emitted entries") }
    }
}

@Test func scanPreservesRawFilenameBytes() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rootDescriptor: Int32 = open(root.path, O_RDONLY | O_DIRECTORY)
    #expect(rootDescriptor >= 0)
    guard rootDescriptor >= 0 else { return }
    defer { _ = close(rootDescriptor) }
    let name: Data = Data([0x66, 0x69, 0x6c, 0x65, 0xc3, 0xa9, 0x0a])
    let descriptor: Int32 = (name + Data([0])).withUnsafeBytes { bytes in
        openat(rootDescriptor, bytes.baseAddress!.assumingMemoryBound(to: CChar.self), O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    }
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    #expect(close(descriptor) == 0)
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    #expect(result.entries.contains { $0.name == name && $0.path == Data(root.path.utf8) + Data([0x2f]) + name })
}

@Test func bulkRecordDecoderPreservesInvalidUTF8AndRejectsInvalidBounds() throws {
    var record: Data = Data()
    var length: UInt32 = 40
    var returned: attribute_set_t = attribute_set_t()
    returned.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_ERROR)
    var errorCode: UInt32 = UInt32(EACCES)
    var reference: attrreference_t = attrreference_t(attr_dataoffset: 8, attr_length: 3)
    withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
    withUnsafeBytes(of: &returned) { record.append(contentsOf: $0) }
    withUnsafeBytes(of: &errorCode) { record.append(contentsOf: $0) }
    withUnsafeBytes(of: &reference) { record.append(contentsOf: $0) }
    record.append(contentsOf: [0x66, 0xff, 0, 0])
    #expect(record.count == 40)
    var cursor: Int = 0
    var decoded: disker_entry_t = disker_entry_t()
    try record.withUnsafeBytes { bytes in
        #expect(disker_decode_entry(bytes.baseAddress!, bytes.count, &cursor, &decoded) == 0)
        #expect(decoded.error_code == UInt32(EACCES))
        let name: UnsafePointer<UInt8> = try #require(decoded.name)
        #expect(Data(bytes: name, count: Int(decoded.name_length)) == Data([0x66, 0xff]))
    }
    #expect(cursor == 40)
    cursor = 0
    record.withUnsafeBytes { bytes in
        #expect(disker_decode_entry(bytes.baseAddress!, 39, &cursor, &decoded) == EBADMSG)
    }
    var invalidOffset: Int32 = 4096
    withUnsafeBytes(of: &invalidOffset) { record.replaceSubrange(28..<32, with: $0) }
    cursor = 0
    record.withUnsafeBytes { bytes in
        #expect(disker_decode_entry(bytes.baseAddress!, bytes.count, &cursor, &decoded) == EBADMSG)
    }
}

@Test func scannerHandlesPathsBeyondPathMaxWithBoundedDescriptors() throws {
    let root: URL = try fixtureDirectory()
    let rootDescriptor: Int32 = open(root.path, O_RDONLY | O_DIRECTORY)
    #expect(rootDescriptor >= 0)
    guard rootDescriptor >= 0 else { return }
    var descriptors: [Int32] = [rootDescriptor]
    let component: String = String(repeating: "d", count: 80)
    defer {
        for index: Int in (1..<descriptors.count).reversed() {
            _ = unlinkat(descriptors[index], "leaf", 0)
            _ = close(descriptors[index])
            #expect(unlinkat(descriptors[index - 1], component, AT_REMOVEDIR) == 0)
        }
        _ = close(rootDescriptor)
        try? FileManager.default.removeItem(at: root)
    }
    for _: Int in 0..<24 {
        #expect(mkdirat(descriptors.last!, component, mode_t(0o700)) == 0)
        let next: Int32 = openat(descriptors.last!, component, O_RDONLY | O_DIRECTORY)
        #expect(next >= 0)
        guard next >= 0 else { return }
        descriptors.append(next)
    }
    let leafDescriptor: Int32 = openat(descriptors.last!, "leaf", O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    #expect(leafDescriptor >= 0)
    guard leafDescriptor >= 0 else { return }
    #expect(close(leafDescriptor) == 0)
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    #expect(result.entries.count == 26)
    #expect(result.summary.metrics.directories == 25)
    #expect(result.summary.issues.isEmpty)
    let leaf: ScanEntry = try #require(result.entries.first { $0.name == Data("leaf".utf8) })
    #expect(leaf.path.count > PATH_MAX)
    let deepRoot: Data = try #require(leaf.parentPath)
    var direct: [ScanEntry] = []
    let directSummary: ScanSummary = try DirectoryScanner.enumerateDirectory(
        path: deepRoot, options: scanOptions(excludedPaths: []), isCancelled: { false }
    ) { direct.append(contentsOf: $0) }
    #expect(direct.count == 2)
    #expect(directSummary.issues.isEmpty)
}

@Test func vanishedDirectoriesAreReportedWithoutAbortingOtherBranches() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let child: URL = root.appendingPathComponent("vanishes")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    var entries: [ScanEntry] = []
    let options: ScanOptions = ScanOptions(batchSize: 1, bufferSize: 4096, mountPolicy: .crossDevices, excludedPaths: [])
    let summary: ScanSummary = try DirectoryScanner.scan(root: Data(root.path.utf8), options: options, isCancelled: { false }) { batch in
        entries.append(contentsOf: batch)
        if batch.contains(where: { $0.path == Data(child.path.utf8) }) {
            try FileManager.default.removeItem(at: child)
        }
    }
    #expect(entries.count == 2)
    #expect(summary.issues.contains { $0.kind == .vanished && $0.path == Data(child.path.utf8) })
    #expect(summary.issues.contains { $0.kind == .changedDuringScan && $0.path == Data(root.path.utf8) })
}

@Test func invalidPathsAndOptionsAreRejectedBeforeScanning() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid: [Data] = [Data(), Data("relative".utf8), Data("/tmp/..".utf8), Data("/tmp//file".utf8), Data([0x2f, 0])]
    for path: Data in invalid {
        #expect(throws: ScanError.invalidPath(path)) {
            try DirectoryScanner.scan(root: path, options: scanOptions(excludedPaths: []), isCancelled: { false }) { _ in }
        }
    }
    #expect(throws: ScanError.invalidOptions("batchSize must be positive and bufferSize must be 4096 through 16777216")) {
        try DirectoryScanner.scan(root: Data(root.path.utf8),
            options: ScanOptions(batchSize: 0, bufferSize: 4096, mountPolicy: .crossDevices, excludedPaths: []),
            isCancelled: { false }) { _ in }
    }
}

@Test func unreadableDirectoriesRetainMetadataAndReportCoverageGap() throws {
    let root: URL = try fixtureDirectory()
    let child: URL = root.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    defer {
        #expect(chmod(child.path, mode_t(0o700)) == 0)
        try? FileManager.default.removeItem(at: root)
    }
    #expect(chmod(child.path, 0) == 0)
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    #expect(result.entries.contains { $0.path == Data(child.path.utf8) && $0.metadata.kind == .directory })
    #expect(result.summary.issues.contains { $0.path == Data(child.path.utf8) && $0.kind == .permissionDenied })
}

@Test func chosenRootSymlinkIsRejectedInsteadOfFollowingTarget() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let alias: URL = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    #expect(throws: ScanError.self) {
        try DirectoryScanner.scan(root: Data(alias.path.utf8), options: scanOptions(excludedPaths: []), isCancelled: { false }) { _ in }
    }
}

@Test func selectedRootAllowsSystemAncestorAliasesWithoutChangingStoredPaths() throws {
    let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-ancestor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("file"))
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    #expect(result.entries.first?.path == Data(root.path.utf8))
    #expect(result.entries.contains { $0.path == Data(root.appendingPathComponent("file").path.utf8) })
    #expect(result.summary.issues.isEmpty)
}

@Test func bulkDeviceIdentityMatchesOpenedSystemDirectory() throws {
    var entries: [ScanEntry] = []
    _ = try DirectoryScanner.enumerateDirectory(path: Data([0x2f]), options: scanOptions(excludedPaths: []), isCancelled: { false }) {
        entries.append(contentsOf: $0)
    }
    let entry: ScanEntry = try #require(entries.first { $0.path == Data("/usr".utf8) })
    let descriptor: Int32 = disker_open_directory("/usr")
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    defer { _ = close(descriptor) }
    var native: disker_metadata_t = disker_metadata_t()
    #expect(disker_metadata_for_descriptor(descriptor, &native) == 0)
    #expect(entry.metadata.device == native.device)
    #expect(entry.metadata.inode == native.inode)
}

@Test func traversalVisitsShallowDirectoriesInDeterministicNameOrder() throws {
    let root: URL = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first: URL = root.appendingPathComponent("a")
    let nested: URL = first.appendingPathComponent("nested")
    let second: URL = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    try Data([1]).write(to: first.appendingPathComponent("first"))
    try Data([2]).write(to: second.appendingPathComponent("second"))
    try Data([3]).write(to: nested.appendingPathComponent("deep"))
    let result: (entries: [ScanEntry], summary: ScanSummary) = try collectScan(root: root)
    let files: [Data] = result.entries.filter { $0.metadata.kind == .regularFile }.map(\.name)
    #expect(files == [Data("first".utf8), Data("second".utf8), Data("deep".utf8)])
}

@Test func scanAliasMappingsPersistRawPaths() throws {
    let alias: ScanAlias = ScanAlias(aliasPath: Data([0x2f, 0x66, 0xff]), targetPath: Data([0x2f, 0x74, 0xfe]))
    let summary: ScanSummary = ScanSummary(
        metrics: ScanMetrics(entries: 1, directories: 1, bulkCalls: 0, metadataCalls: 0, contentBytesRead: 0),
        issues: [ScanIssue(kind: .directoryAlias, path: alias.aliasPath, operation: "descend", errnoCode: 0)],
        aliases: [alias])
    let stored: Data = try JSONEncoder().encode(summary)
    let decoded: ScanSummary = try JSONDecoder().decode(ScanSummary.self, from: stored)
    #expect(decoded == summary)
}

@Test func boundedSystemFirmlinkScanReturnsCanonicalAliasWithoutWalkingUserContents() throws {
    let directories: [Data] = ["/", "/Users", "/System", "/System/Volumes", "/System/Volumes/Data"].map { Data($0.utf8) }
    let retained: Set<Data> = Set(directories + [Data("/System/Volumes/Data/Users".utf8)])
    var excluded: Set<Data> = []
    for directory: Data in directories {
        _ = try DirectoryScanner.enumerateDirectory(path: directory, options: scanOptions(excludedPaths: []), isCancelled: { false }) { batch in
            for entry: ScanEntry in batch where entry.path != directory && !retained.contains(entry.path) {
                excluded.insert(entry.path)
            }
        }
    }
    let options: ScanOptions = ScanOptions(batchSize: 2, bufferSize: 4096, mountPolicy: .crossDevices, excludedPaths: Array(excluded))
    let summary: ScanSummary = try DirectoryScanner.scan(root: Data([0x2f]), options: options, isCancelled: { false }) { _ in }
    #expect(summary.metrics.directories == 5)
    #expect(summary.aliases == [ScanAlias(aliasPath: Data("/System/Volumes/Data/Users".utf8), targetPath: Data("/Users".utf8))])
    #expect(summary.aliases.allSatisfy { alias in
        alias.aliasPath != alias.targetPath && !summary.aliases.contains(where: { $0.aliasPath == alias.targetPath })
    })
}
