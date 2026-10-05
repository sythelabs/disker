import ArgumentParser
import Darwin
import DiskerCore
import Foundation

@main
struct DiskerIndexCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "disker-index",
        abstract: "Scan, cache, query, and benchmark macOS disk metadata.",
        subcommands: [ScanCommand.self, SummaryCommand.self, ChildrenCommand.self, GitCommand.self, BenchmarkCommand.self]
    )
}

struct CacheArguments: ParsableArguments {
    @Option(name: .long, help: "SQLite cache path.")
    var cache: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Disker/index.sqlite").path

    var databaseURL: URL { URL(fileURLWithPath: expandedPath(cache)).standardizedFileURL }
}

struct ScanCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(commandName: "scan", abstract: "Refresh the persistent file tree; omit root to start at /.")

    @Argument(help: "Directory to scan. Defaults to /, with home used if opening / is denied.")
    var root: String?

    @OptionGroup var storage: CacheArguments

    @Flag(name: .long, help: "Force a full metadata scan instead of journal-based reconciliation.")
    var full: Bool = false

    mutating func run() async throws {
        let index: DiskIndex = try DiskIndex(databaseURL: storage.databaseURL)
        let mode: RefreshMode = full ? .full : .automatic
        let requested: String = expandedPath(root ?? "/")
        let summary: IndexSummary
        do {
            summary = try await refreshWithProgress(index: index, root: requested, mode: mode)
        } catch ScanError.systemCall(let path, _, let code) where root == nil && path == Data("/".utf8) && (code == EACCES || code == EPERM) {
            summary = try await refreshWithProgress(index: index, root: FileManager.default.homeDirectoryForCurrentUser.path, mode: mode)
        }
        try writeJSON(summary)
    }
}

struct SummaryCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(commandName: "summary", abstract: "Read a cached summary without scanning.")

    @Argument var root: String
    @OptionGroup var storage: CacheArguments

    mutating func run() async throws {
        let index: DiskIndex = try DiskIndex(databaseURL: storage.databaseURL)
        let path: String = expandedPath(root)
        guard let summary: IndexSummary = try await index.cachedSummary(root: path) else {
            throw CLIError.missingCache(root: path)
        }
        try writeJSON(summary)
    }
}

struct ChildrenCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(commandName: "children", abstract: "Query one directory page from the cached tree.")

    @Argument var root: String
    @Argument(help: "Directory to query; defaults to root.") var directory: String?
    @OptionGroup var storage: CacheArguments
    @Option(name: .long) var offset: Int = 0
    @Option(name: .long) var limit: Int = 100

    mutating func validate() throws {
        guard offset >= 0, limit > 0, limit <= 10_000 else {
            throw ValidationError("offset must be nonnegative and limit must be 1 through 10000")
        }
    }

    mutating func run() async throws {
        let index: DiskIndex = try DiskIndex(databaseURL: storage.databaseURL)
        let rootPath: String = expandedPath(root)
        let directoryPath: String = URL(fileURLWithPath: expandedPath(directory ?? root)).standardizedFileURL.path
        guard try await index.cachedSummary(root: rootPath) != nil else { throw CLIError.missingCache(root: rootPath) }
        guard let parent: IndexedNode = try await index.node(root: rootPath, path: Data(directoryPath.utf8)) else {
            throw ValidationError("No cached directory at \(directoryPath)")
        }
        guard parent.entry.metadata.kind == .directory else { throw ValidationError("Cached path is not a directory: \(directoryPath)") }
        let nodes: [IndexedNode] = try await index.children(root: rootPath, directory: Data(directoryPath.utf8), offset: offset, limit: limit)
        try writeJSON(nodes)
    }
}

struct GitCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(commandName: "git", abstract: "Inspect repository metadata separately from the disk scan, reusing cached Git results.")

    @Argument var root: String
    @Argument var path: String
    @OptionGroup var storage: CacheArguments

    mutating func run() async throws {
        let index: DiskIndex = try DiskIndex(databaseURL: storage.databaseURL)
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let result: CachedGitInfo? = try await index.gitInfo(root: expandedPath(root), path: expandedPath(path), inspector: inspector)
        try writeJSON(result)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingCache(root: String)
    case outputFailed(stream: String, diagnostic: String)
    case benchmarkVerification(String)
    case processFailed(executable: String, status: Int32, stderr: String)
    case resourceUsage(operation: String, code: Int32)

    var description: String {
        switch self {
        case let .missingCache(root): return "No cached tree for \(root); run disker-index scan first"
        case let .outputFailed(stream, diagnostic): return "Cannot write \(stream): \(diagnostic)"
        case let .benchmarkVerification(message): return "Benchmark verification failed: \(message)"
        case let .processFailed(executable, status, stderr): return "Cache-query process failed: executable=\(executable), status=\(status), stderr=\(stderr)"
        case let .resourceUsage(operation, code): return "Resource measurement failed: operation=\(operation), errno=\(code), diagnostic=\(String(cString: strerror(code)))"
        }
    }
}

private struct ProgressRecord: Encodable {
    let event: String
    let root: String
    let entriesObserved: Int64?
    let logicalBytesObserved: UInt64?
    let elapsedSeconds: Double?
    let previousNodeCount: Int64?
    let isComplete: Bool?
    let completionFraction: Double?
}

private final class ProgressWriter: @unchecked Sendable {
    private let root: String
    private let lock: NSLock = NSLock()
    private var lastElapsed: Double = -0.5
    private var failure: CLIError?

    init(root: String) { self.root = root }

    func receive(_ event: IndexEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        let record: ProgressRecord
        switch event {
        case .waitingForWriter:
            record = ProgressRecord(event: "waiting_for_writer", root: root, entriesObserved: nil, logicalBytesObserved: nil, elapsedSeconds: nil, previousNodeCount: nil, isComplete: nil, completionFraction: nil)
        case .writerAcquired:
            record = ProgressRecord(event: "writer_acquired", root: root, entriesObserved: nil, logicalBytesObserved: nil, elapsedSeconds: nil, previousNodeCount: nil, isComplete: nil, completionFraction: nil)
        case let .started(cached):
            record = ProgressRecord(event: "started", root: root, entriesObserved: nil, logicalBytesObserved: nil, elapsedSeconds: nil, previousNodeCount: cached?.nodeCount, isComplete: cached?.isComplete, completionFraction: 0)
        case .batch:
            return
        case let .progress(progress):
            guard progress.elapsedSeconds - lastElapsed >= 0.5 else { return }
            lastElapsed = progress.elapsedSeconds
            record = ProgressRecord(event: "progress", root: root, entriesObserved: progress.entriesObserved, logicalBytesObserved: progress.logicalBytesObserved, elapsedSeconds: progress.elapsedSeconds, previousNodeCount: progress.previousNodeCount, isComplete: nil, completionFraction: progress.completionFraction)
        case let .completed(summary):
            record = ProgressRecord(event: "completed", root: root, entriesObserved: summary.nodeCount, logicalBytesObserved: summary.logicalBytes, elapsedSeconds: nil, previousNodeCount: nil, isComplete: summary.isComplete, completionFraction: 1)
        }
        do {
            var data: Data = try JSONEncoder().encode(record)
            data.append(10)
            try FileHandle.standardError.write(contentsOf: data)
        } catch {
            failure = .outputFailed(stream: "stderr", diagnostic: String(describing: error))
        }
    }

    func reportedFailure() -> CLIError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

func refreshWithProgress(index: DiskIndex, root: String, mode: RefreshMode) async throws -> IndexSummary {
    let progress: ProgressWriter = ProgressWriter(root: root)
    let summary: IndexSummary
    do {
        summary = try await index.refresh(root: root, mode: mode, receiveEvent: { progress.receive($0) }, isCancelled: { Task<Never, Never>.isCancelled || progress.reportedFailure() != nil })
    } catch {
        if let failure: CLIError = progress.reportedFailure() { throw failure }
        throw error
    }
    if let failure: CLIError = progress.reportedFailure() { throw failure }
    return summary
}

func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var data: Data = try encoder.encode(value)
    data.append(10)
    do {
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
        throw CLIError.outputFailed(stream: "stdout", diagnostic: String(describing: error))
    }
}

func expandedPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}
