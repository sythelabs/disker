import Foundation

public enum FileKind: String, Codable, Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case socket
    case fifo
    case characterDevice
    case blockDevice
    case unknown
}

public struct FileTimestamp: Codable, Equatable, Sendable {
    public let seconds: Int64
    public let nanoseconds: Int32

    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

public struct FileMetadata: Codable, Equatable, Sendable {
    public let kind: FileKind
    public let device: UInt64
    public let inode: UInt64
    public let linkCount: UInt32
    public let mode: UInt32
    public let ownerID: UInt32
    public let groupID: UInt32
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let birthTime: FileTimestamp
    public let modificationTime: FileTimestamp
    public let changeTime: FileTimestamp
    public let accessTime: FileTimestamp
    public let flags: UInt32

    public init(kind: FileKind, device: UInt64, inode: UInt64, linkCount: UInt32, mode: UInt32,
                ownerID: UInt32, groupID: UInt32, logicalBytes: UInt64, allocatedBytes: UInt64,
                birthTime: FileTimestamp, modificationTime: FileTimestamp, changeTime: FileTimestamp,
                accessTime: FileTimestamp, flags: UInt32) {
        self.kind = kind
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.mode = mode
        self.ownerID = ownerID
        self.groupID = groupID
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.birthTime = birthTime
        self.modificationTime = modificationTime
        self.changeTime = changeTime
        self.accessTime = accessTime
        self.flags = flags
    }
}

public struct ScanEntry: Codable, Equatable, Sendable {
    public let path: Data
    public let parentPath: Data?
    public let name: Data
    public let metadata: FileMetadata

    public init(path: Data, parentPath: Data?, name: Data, metadata: FileMetadata) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.metadata = metadata
    }
}
