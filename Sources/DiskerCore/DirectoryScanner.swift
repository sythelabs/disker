import CDiskerScan
import Darwin
import Foundation

public enum MountPolicy: String, Codable, Equatable, Sendable {
    case sameDevice
    case crossDevices
}

public struct ScanOptions: Sendable {
    public let batchSize: Int
    public let bufferSize: Int
    public let mountPolicy: MountPolicy
    public let excludedPaths: [Data]

    public init(batchSize: Int, bufferSize: Int, mountPolicy: MountPolicy, excludedPaths: [Data]) {
        self.batchSize = batchSize
        self.bufferSize = bufferSize
        self.mountPolicy = mountPolicy
        self.excludedPaths = excludedPaths
    }
}

public enum ScanIssueKind: String, Codable, Sendable {
    case permissionDenied
    case vanished
    case metadataUnavailable
    case ioError
    case mountBoundary
    case directoryAlias
    case excluded
    case changedDuringScan
}

public struct ScanIssue: Codable, Equatable, Sendable {
    public let kind: ScanIssueKind
    public let path: Data
    public let operation: String
    public let errnoCode: Int32

    public init(kind: ScanIssueKind, path: Data, operation: String, errnoCode: Int32) {
        self.kind = kind
        self.path = path
        self.operation = operation
        self.errnoCode = errnoCode
    }
}

public struct ScanMetrics: Codable, Equatable, Sendable {
    public var entries: Int64
    public var directories: Int64
    public var bulkCalls: Int64
    public var metadataCalls: Int64
    public var contentBytesRead: Int64

    public init(entries: Int64, directories: Int64, bulkCalls: Int64, metadataCalls: Int64, contentBytesRead: Int64) {
        self.entries = entries
        self.directories = directories
        self.bulkCalls = bulkCalls
        self.metadataCalls = metadataCalls
        self.contentBytesRead = contentBytesRead
    }
}

public struct ScanAlias: Codable, Equatable, Sendable {
    public let aliasPath: Data
    public let targetPath: Data

    public init(aliasPath: Data, targetPath: Data) {
        self.aliasPath = aliasPath
        self.targetPath = targetPath
    }
}

public struct ScanSummary: Codable, Equatable, Sendable {
    public let metrics: ScanMetrics
    public let issues: [ScanIssue]
    public let aliases: [ScanAlias]

    public init(metrics: ScanMetrics, issues: [ScanIssue], aliases: [ScanAlias]) {
        self.metrics = metrics
        self.issues = issues
        self.aliases = aliases
    }
}

public enum ScanError: Error, Equatable, Sendable {
    case cancelled
    case invalidOptions(String)
    case invalidPath(Data)
    case systemCall(path: Data, operation: String, errnoCode: Int32)
    case malformedRecord(path: Data, errnoCode: Int32)
}

private struct DirectoryIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

private struct DirectoryJob {
    let path: Data
    let metadata: FileMetadata
    let progressWeight: Double
}

public enum DirectoryScanner {
    public static func scan(root: Data, options: ScanOptions, isCancelled: @Sendable () -> Bool,
                            receiveProgress: (Double) -> Void,
                            receiveBatch: ([ScanEntry]) throws -> Void) throws -> ScanSummary {
        try validate(root: root, options: options)
        if isCancelled() { throw ScanError.cancelled }
        let rootDescriptor: Int32 = openRoot(root)
        guard rootDescriptor >= 0 else {
            throw ScanError.systemCall(path: root, operation: "open", errnoCode: errno)
        }
        defer { _ = close(rootDescriptor) }
        var native: disker_metadata_t = disker_metadata_t()
        let metadataError: Int32 = disker_metadata_for_descriptor(rootDescriptor, &native)
        guard metadataError == 0 else {
            throw ScanError.systemCall(path: root, operation: "fstat", errnoCode: metadataError)
        }
        let rootMetadata: FileMetadata = metadata(native)
        var metrics: ScanMetrics = ScanMetrics(entries: 0, directories: 0, bulkCalls: 0, metadataCalls: 1, contentBytesRead: 0)
        var issues: [ScanIssue] = []
        var aliases: [ScanAlias] = []
        var jobs: [DirectoryJob] = [DirectoryJob(path: root, metadata: rootMetadata, progressWeight: 1)]
        var nextJob: Int = 0
        var completedWeight: Double = 0
        func completeWork(_ weight: Double) {
            completedWeight += weight
            receiveProgress(min(completedWeight, Double(1).nextDown))
        }
        var visited: [DirectoryIdentity: Data] = [:]
        var batch: [ScanEntry] = []
        batch.reserveCapacity(options.batchSize)
        let buffer: UnsafeMutableRawPointer = UnsafeMutableRawPointer.allocate(byteCount: options.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        batch.append(rootEntry(path: root, metadata: rootMetadata))
        metrics.entries += 1
        if batch.count == options.batchSize {
            try receiveBatch(batch)
            batch.removeAll(keepingCapacity: true)
        }
        while nextJob < jobs.count {
            let job: DirectoryJob = jobs[nextJob]
            nextJob += 1
            if nextJob >= 4096 && nextJob >= jobs.count / 2 {
                jobs.removeFirst(nextJob)
                nextJob = 0
            }
            if isCancelled() { throw ScanError.cancelled }
            let relative: Data = relativePath(job.path, root: root)
            let descriptor: Int32 = openRelative(rootDescriptor: rootDescriptor, path: relative)
            if descriptor < 0 {
                issues.append(systemIssue(path: job.path, operation: "openat", code: errno))
                completeWork(job.progressWeight)
                continue
            }
            do {
                var openedNative: disker_metadata_t = disker_metadata_t()
                let openedError: Int32 = disker_metadata_for_descriptor(descriptor, &openedNative)
                metrics.metadataCalls += 1
                if openedError != 0 {
                    issues.append(systemIssue(path: job.path, operation: "fstat", code: openedError))
                    _ = close(descriptor)
                    completeWork(job.progressWeight)
                    continue
                }
                let opened: FileMetadata = metadata(openedNative)
                if options.mountPolicy == .sameDevice && opened.device != rootMetadata.device {
                    issues.append(ScanIssue(kind: .mountBoundary, path: job.path, operation: "descend", errnoCode: 0))
                    _ = close(descriptor)
                    completeWork(job.progressWeight)
                    continue
                }
                let identity: DirectoryIdentity = DirectoryIdentity(device: opened.device, inode: opened.inode)
                if let canonicalPath: Data = visited[identity] {
                    if canonicalPath == job.path {
                        issues.append(ScanIssue(kind: .changedDuringScan, path: job.path, operation: "duplicateDirectoryEntry", errnoCode: 0))
                    } else {
                        aliases.append(ScanAlias(aliasPath: job.path, targetPath: canonicalPath))
                        issues.append(ScanIssue(kind: .directoryAlias, path: job.path, operation: "descend", errnoCode: 0))
                    }
                    _ = close(descriptor)
                    completeWork(job.progressWeight)
                    continue
                }
                visited[identity] = job.path
                if opened.device != job.metadata.device || opened.inode != job.metadata.inode ||
                    opened.modificationTime != job.metadata.modificationTime || opened.changeTime != job.metadata.changeTime {
                    issues.append(ScanIssue(kind: .changedDuringScan, path: job.path, operation: "verifyDirectory", errnoCode: 0))
                }
                metrics.directories += 1
                var childDirectories: [ScanEntry] = []
                let enumeration: ScanSummary = try enumerateOpenedDirectory(descriptor: descriptor, path: job.path, options: options,
                    buffer: buffer, isCancelled: isCancelled, receiveEntry: { entry in
                        if entry.metadata.kind == .directory {
                            childDirectories.append(entry)
                        }
                        batch.append(entry)
                        metrics.entries += 1
                        if batch.count == options.batchSize {
                            try receiveBatch(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    })
                let progressWeight: Double = job.progressWeight / Double(childDirectories.count + 1)
                for entry: ScanEntry in childDirectories.sorted(by: { $0.path.lexicographicallyPrecedes($1.path) }) {
                    jobs.append(DirectoryJob(path: entry.path, metadata: entry.metadata, progressWeight: progressWeight))
                }
                metrics.bulkCalls += enumeration.metrics.bulkCalls
                metrics.metadataCalls += enumeration.metrics.metadataCalls
                issues.append(contentsOf: enumeration.issues)
                var after: disker_metadata_t = disker_metadata_t()
                let afterError: Int32 = disker_metadata_for_descriptor(descriptor, &after)
                metrics.metadataCalls += 1
                if afterError != 0 {
                    issues.append(systemIssue(path: job.path, operation: "fstatAfterScan", code: afterError))
                } else if after.modification_time.seconds != opened.modificationTime.seconds ||
                    after.modification_time.nanoseconds != opened.modificationTime.nanoseconds ||
                    after.change_time.seconds != opened.changeTime.seconds ||
                    after.change_time.nanoseconds != opened.changeTime.nanoseconds {
                    issues.append(ScanIssue(kind: .changedDuringScan, path: job.path, operation: "verifyDirectory", errnoCode: 0))
                }
                _ = close(descriptor)
                completeWork(progressWeight)
            } catch {
                _ = close(descriptor)
                throw error
            }
        }
        if !batch.isEmpty { try receiveBatch(batch) }
        if isCancelled() { throw ScanError.cancelled }
        receiveProgress(1)
        return ScanSummary(metrics: metrics, issues: issues, aliases: aliases)
    }

    public static func enumerateDirectory(path: Data, options: ScanOptions, isCancelled: @Sendable () -> Bool,
                                         receiveProgress: (Double) -> Void,
                                         receiveBatch: ([ScanEntry]) throws -> Void) throws -> ScanSummary {
        try validate(root: path, options: options)
        if isCancelled() { throw ScanError.cancelled }
        let descriptor: Int32 = openRoot(path)
        guard descriptor >= 0 else {
            throw ScanError.systemCall(path: path, operation: "open", errnoCode: errno)
        }
        defer { _ = close(descriptor) }
        var native: disker_metadata_t = disker_metadata_t()
        let metadataError: Int32 = disker_metadata_for_descriptor(descriptor, &native)
        guard metadataError == 0 else {
            throw ScanError.systemCall(path: path, operation: "fstat", errnoCode: metadataError)
        }
        var metrics: ScanMetrics = ScanMetrics(entries: 1, directories: 1, bulkCalls: 0, metadataCalls: 1, contentBytesRead: 0)
        var issues: [ScanIssue] = []
        var batch: [ScanEntry] = [rootEntry(path: path, metadata: metadata(native))]
        batch.reserveCapacity(options.batchSize)
        let buffer: UnsafeMutableRawPointer = UnsafeMutableRawPointer.allocate(byteCount: options.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        if batch.count == options.batchSize {
            try receiveBatch(batch)
            batch.removeAll(keepingCapacity: true)
        }
        let enumeration: ScanSummary = try enumerateOpenedDirectory(descriptor: descriptor, path: path, options: options, buffer: buffer,
            isCancelled: isCancelled, receiveEntry: { entry in
                batch.append(entry)
                metrics.entries += 1
                if batch.count == options.batchSize {
                    try receiveBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            })
        metrics.bulkCalls += enumeration.metrics.bulkCalls
        metrics.metadataCalls += enumeration.metrics.metadataCalls
        issues.append(contentsOf: enumeration.issues)
        var after: disker_metadata_t = disker_metadata_t()
        let afterError: Int32 = disker_metadata_for_descriptor(descriptor, &after)
        metrics.metadataCalls += 1
        if afterError != 0 {
            issues.append(systemIssue(path: path, operation: "fstatAfterScan", code: afterError))
        } else if native.modification_time.seconds != after.modification_time.seconds ||
            native.modification_time.nanoseconds != after.modification_time.nanoseconds ||
            native.change_time.seconds != after.change_time.seconds ||
            native.change_time.nanoseconds != after.change_time.nanoseconds {
            issues.append(ScanIssue(kind: .changedDuringScan, path: path, operation: "verifyDirectory", errnoCode: 0))
        }
        if !batch.isEmpty { try receiveBatch(batch) }
        if isCancelled() { throw ScanError.cancelled }
        receiveProgress(1)
        return ScanSummary(metrics: metrics, issues: issues, aliases: [])
    }

    private static func enumerateOpenedDirectory(descriptor: Int32, path: Data, options: ScanOptions,
                                                buffer: UnsafeMutableRawPointer, isCancelled: @Sendable () -> Bool,
                                                receiveEntry: (ScanEntry) throws -> Void) throws -> ScanSummary {
        var metrics: ScanMetrics = ScanMetrics(entries: 0, directories: 0, bulkCalls: 0, metadataCalls: 0, contentBytesRead: 0)
        var issues: [ScanIssue] = []
        while true {
            if isCancelled() { throw ScanError.cancelled }
            let count: Int32 = disker_read_directory(descriptor, buffer, options.bufferSize)
            metrics.bulkCalls += 1
            if count < 0 {
                issues.append(systemIssue(path: path, operation: "getattrlistbulk", code: errno))
                return ScanSummary(metrics: metrics, issues: issues, aliases: [])
            }
            if count == 0 { return ScanSummary(metrics: metrics, issues: issues, aliases: []) }
            var cursor: Int = 0
            for _: Int32 in 0..<count {
                if isCancelled() { throw ScanError.cancelled }
                var native: disker_entry_t = disker_entry_t()
                let decodeError: Int32 = disker_decode_entry(buffer, options.bufferSize, &cursor, &native)
                guard decodeError == 0, let nativeName: UnsafePointer<UInt8> = native.name else {
                    throw ScanError.malformedRecord(path: path, errnoCode: decodeError)
                }
                let name: Data = Data(bytes: nativeName, count: Int(native.name_length))
                if name == Data(".".utf8) || name == Data("..".utf8) { continue }
                var childPath: Data = Data()
                childPath.reserveCapacity(path.count + 1 + name.count)
                childPath.append(path)
                if path.count != 1 { childPath.append(0x2f) }
                childPath.append(name)
                if options.excludedPaths.contains(childPath) {
                    issues.append(ScanIssue(kind: .excluded, path: childPath, operation: "enumerate", errnoCode: 0))
                    continue
                }
                if native.error_code != 0 {
                    issues.append(systemIssue(path: childPath, operation: "entryMetadata", code: Int32(native.error_code)))
                    continue
                }
                var childMetadata: FileMetadata = metadata(native.metadata)
                if childMetadata.kind == .directory && (native.mount_status != 0 || native.metadata.flags & UInt32(SF_FIRMLINK) != 0) {
                    let childDescriptor: Int32 = openRelative(rootDescriptor: descriptor, path: name)
                    if childDescriptor < 0 {
                        issues.append(systemIssue(path: childPath, operation: "openMountTarget", code: errno))
                    } else {
                        var target: disker_metadata_t = disker_metadata_t()
                        let targetError: Int32 = disker_metadata_for_descriptor(childDescriptor, &target)
                        metrics.metadataCalls += 1
                        _ = close(childDescriptor)
                        if targetError != 0 {
                            issues.append(systemIssue(path: childPath, operation: "fstatMountTarget", code: targetError))
                        } else {
                            childMetadata = metadata(target)
                        }
                    }
                }
                try receiveEntry(ScanEntry(path: childPath, parentPath: path, name: name, metadata: childMetadata))
            }
        }
    }

    private static func validate(root: Data, options: ScanOptions) throws {
        guard options.batchSize > 0, options.bufferSize >= 4096, options.bufferSize <= 16 * 1024 * 1024 else {
            throw ScanError.invalidOptions("batchSize must be positive and bufferSize must be 4096 through 16777216")
        }
        guard root.first == 0x2f, !root.contains(0), root.count == 1 || root.last != 0x2f,
              !root.split(separator: 0x2f).contains(where: { $0 == Data(".".utf8) || $0 == Data("..".utf8) }),
              root.count == 1 || !root.dropFirst().split(separator: 0x2f, omittingEmptySubsequences: false).contains(where: { $0.isEmpty }) else {
            throw ScanError.invalidPath(root)
        }
    }

    private static func rootEntry(path: Data, metadata: FileMetadata) -> ScanEntry {
        let name: Data = path == Data([0x2f]) ? path : Data(path.split(separator: 0x2f).last!)
        return ScanEntry(path: path, parentPath: nil, name: name, metadata: metadata)
    }

    private static func relativePath(_ path: Data, root: Data) -> Data {
        path == root ? Data() : Data(path.dropFirst(root.count + (root == Data([0x2f]) ? 0 : 1)))
    }

    private static func openRoot(_ path: Data) -> Int32 {
        (path + Data([0])).withUnsafeBytes { bytes in
            disker_open_directory(bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func openRelative(rootDescriptor: Int32, path: Data) -> Int32 {
        (path + Data([0])).withUnsafeBytes { bytes in
            disker_open_directory_relative(rootDescriptor, bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func metadata(_ value: disker_metadata_t) -> FileMetadata {
        let kind: FileKind
        switch value.mode & UInt32(S_IFMT) {
        case UInt32(S_IFREG): kind = .regularFile
        case UInt32(S_IFDIR): kind = .directory
        case UInt32(S_IFLNK): kind = .symbolicLink
        case UInt32(S_IFSOCK): kind = .socket
        case UInt32(S_IFIFO): kind = .fifo
        case UInt32(S_IFCHR): kind = .characterDevice
        case UInt32(S_IFBLK): kind = .blockDevice
        default: kind = .unknown
        }
        return FileMetadata(kind: kind, device: value.device, inode: value.inode, linkCount: value.link_count,
            mode: value.mode, ownerID: value.owner_id, groupID: value.group_id, logicalBytes: value.logical_bytes,
            allocatedBytes: value.allocated_bytes,
            birthTime: FileTimestamp(seconds: value.birth_time.seconds, nanoseconds: value.birth_time.nanoseconds),
            modificationTime: FileTimestamp(seconds: value.modification_time.seconds, nanoseconds: value.modification_time.nanoseconds),
            changeTime: FileTimestamp(seconds: value.change_time.seconds, nanoseconds: value.change_time.nanoseconds),
            accessTime: FileTimestamp(seconds: value.access_time.seconds, nanoseconds: value.access_time.nanoseconds), flags: value.flags)
    }

    private static func systemIssue(path: Data, operation: String, code: Int32) -> ScanIssue {
        let kind: ScanIssueKind
        switch code {
        case EACCES, EPERM: kind = .permissionDenied
        case ENOENT, ENOTDIR, ELOOP: kind = .vanished
        case ENOTSUP: kind = .metadataUnavailable
        default: kind = .ioError
        }
        return ScanIssue(kind: kind, path: path, operation: operation, errnoCode: code)
    }
}
