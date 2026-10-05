import Foundation

public enum RefreshMode: Equatable, Sendable {
    case automatic
    case full
    case directories([Data])
}

public struct IndexedNode: Codable, Equatable, Sendable {
    public let entry: ScanEntry
    public let subtreeLogicalBytes: UInt64
    public let subtreeAllocatedBytes: UInt64
    public let subtreeNodeCount: Int64
    public let aliasTargetPath: Data?

    public init(entry: ScanEntry, subtreeLogicalBytes: UInt64, subtreeAllocatedBytes: UInt64, subtreeNodeCount: Int64, aliasTargetPath: Data?) {
        self.entry = entry
        self.subtreeLogicalBytes = subtreeLogicalBytes
        self.subtreeAllocatedBytes = subtreeAllocatedBytes
        self.subtreeNodeCount = subtreeNodeCount
        self.aliasTargetPath = aliasTargetPath
    }
}

public struct CachedGitInfo: Codable, Sendable {
    public let info: GitRepositoryInfo
    public let wasCached: Bool
}

public struct IndexSummary: Codable, Equatable, Sendable {
    public let root: String
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let nodeCount: Int64
    public let revision: Int64
    public let lastScanDate: Date
    public let isComplete: Bool
    public let issues: [ScanIssue]
    public let metrics: ScanMetrics
}

public struct IndexProgress: Sendable {
    public let entriesObserved: Int64
    public let logicalBytesObserved: UInt64
    public let allocatedBytesObserved: UInt64
    public let elapsedSeconds: Double
    public let previousNodeCount: Int64?
}

public enum IndexEvent: Sendable {
    case started(cached: IndexSummary?)
    case waitingForWriter
    case writerAcquired
    case batch([ScanEntry])
    case progress(IndexProgress)
    case completed(IndexSummary)
}

public enum IndexError: Error, Sendable {
    case invalidQuery(String)
    case incompatibleSchema(Int32)
    case malformedCache(String)
    case unstableFilesystem(String)
    case staleEnrichment(String)
}
