import ArgumentParser
import Darwin
import DiskerCore
import Foundation

struct BenchmarkCommand: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(commandName: "benchmark", abstract: "Measure a deterministic temporary fixture or a supplied read-only root.")

    @Option(name: .long, help: "Fixture file count, 1 through 500000; ignored when root is supplied.")
    var files: Int = 20_000

    @Option(name: .long, help: "Existing directory to scan without modifying its files.")
    var root: String?

    mutating func validate() throws {
        guard files >= 1, files <= 500_000 else { throw ValidationError("files must be 1 through 500000") }
    }

    mutating func run() async throws {
        let workspace: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let report: BenchmarkReport
        do {
            report = try await runBenchmark(workspace: workspace, suppliedRoot: root, fileCount: files)
        } catch {
            do {
                try FileManager.default.removeItem(at: workspace)
            } catch let cleanupError {
                throw CLIError.benchmarkVerification("\(error); cleanup failed for \(workspace.path): \(cleanupError)")
            }
            throw error
        }
        try FileManager.default.removeItem(at: workspace)
        try writeJSON(report)
        guard report.verificationFailures.isEmpty else {
            throw CLIError.benchmarkVerification(report.verificationFailures.joined(separator: "; "))
        }
    }
}

private struct BenchmarkReport: Codable {
    let root: String
    let fixtureFiles: Int?
    let fixtureCreationSeconds: Double?
    let buildConfiguration: String
    let filesystemCacheState: String
    let refreshConsistency: String
    let fullScanSeconds: Double
    let fullScanNodesPerSecond: Double
    let fullScan: IndexSummary
    let reopenAndQuerySeconds: Double
    let freshProcessCachedQuerySeconds: Double
    let cachedChildrenReturned: Int
    let unchangedRefreshSeconds: Double
    let unchangedRefresh: IndexSummary
    let singleFileResizeConvergenceSeconds: Double?
    let singleFileResizeRefreshSeconds: Double?
    let resizeRefreshAttempts: Int?
    let singleFileResize: IndexSummary?
    let cacheLogicalBytes: UInt64
    let cacheAllocatedBytes: UInt64
    let peakResidentBytes: UInt64
    let verificationFailures: [String]
}

private func runBenchmark(workspace: URL, suppliedRoot: String?, fileCount: Int) async throws -> BenchmarkReport {
    let root: URL
    let fixtureCreationSeconds: Double?
    if let suppliedRoot {
        root = URL(fileURLWithPath: expandedPath(suppliedRoot)).standardizedFileURL
        fixtureCreationSeconds = nil
    } else {
        root = workspace.appendingPathComponent("fixture")
        let creationStart: ContinuousClock.Instant = ContinuousClock.now
        try createBenchmarkFixture(root: root, fileCount: fileCount)
        fixtureCreationSeconds = benchmarkSeconds(since: creationStart)
    }
    let database: URL = workspace.appendingPathComponent("cache/index.sqlite")
    let index: DiskIndex = try DiskIndex(databaseURL: database)
    let fullStart: ContinuousClock.Instant = ContinuousClock.now
    let full: IndexSummary = try await refreshWithProgress(index: index, root: root.path, mode: .full)
    let fullSeconds: Double = benchmarkSeconds(since: fullStart)

    let reopenStart: ContinuousClock.Instant = ContinuousClock.now
    let reopened: DiskIndex = try DiskIndex(databaseURL: database)
    guard let cached: IndexSummary = try await reopened.cachedSummary(root: root.path) else {
        throw CLIError.benchmarkVerification("Cached root disappeared after reopening SQLite")
    }
    let children: [IndexedNode] = try await reopened.children(root: root.path, directory: Data(root.path.utf8), offset: 0, limit: 100)
    let reopenSeconds: Double = benchmarkSeconds(since: reopenStart)
    guard cached.nodeCount == full.nodeCount, cached.logicalBytes == full.logicalBytes, cached.revision == full.revision else {
        throw CLIError.benchmarkVerification("Reopened summary differs from the persisted full scan")
    }
    let processStart: ContinuousClock.Instant = ContinuousClock.now
    let processSummary: IndexSummary = try readSummaryInFreshProcess(root: root.path, database: database)
    let processSeconds: Double = benchmarkSeconds(since: processStart)
    guard processSummary.nodeCount == full.nodeCount, processSummary.logicalBytes == full.logicalBytes, processSummary.revision == full.revision else {
        throw CLIError.benchmarkVerification("Fresh-process summary differs from the persisted full scan")
    }

    let unchangedStart: ContinuousClock.Instant = ContinuousClock.now
    let unchanged: IndexSummary = try await refreshWithProgress(index: reopened, root: root.path, mode: .automatic)
    let unchangedSeconds: Double = benchmarkSeconds(since: unchangedStart)
    var verificationFailures: [String] = []
    if suppliedRoot == nil {
        if unchanged.nodeCount != full.nodeCount || unchanged.logicalBytes != full.logicalBytes {
            verificationFailures.append("Unchanged fixture refresh altered node count or logical bytes")
        }
    }

    let resized: IndexSummary?
    let resizeSeconds: Double?
    let successfulResizeRefreshSeconds: Double?
    let resizeRefreshAttempts: Int?
    if suppliedRoot == nil {
        let changedFile: URL = root.appendingPathComponent("group-0/file-0")
        try Data(repeating: 42, count: 8192).write(to: changedFile)
        let resizeStart: ContinuousClock.Instant = ContinuousClock.now
        var attemptStart: ContinuousClock.Instant = ContinuousClock.now
        var summary: IndexSummary = try await refreshWithProgress(index: reopened, root: root.path, mode: .automatic)
        var attemptSeconds: Double = benchmarkSeconds(since: attemptStart)
        var attempts: Int = 1
        var node: IndexedNode? = try await reopened.node(root: root.path, path: Data(changedFile.path.utf8))
        while (node?.entry.metadata.logicalBytes != 8192 || summary.logicalBytes != unchanged.logicalBytes + 8160 || summary.nodeCount != unchanged.nodeCount),
              benchmarkSeconds(since: resizeStart) < 5 {
            try await Task.sleep(for: .milliseconds(10))
            attemptStart = ContinuousClock.now
            summary = try await reopened.refresh(root: root.path, mode: .automatic, receiveEvent: { _ in }, isCancelled: { Task<Never, Never>.isCancelled })
            attemptSeconds = benchmarkSeconds(since: attemptStart)
            attempts += 1
            node = try await reopened.node(root: root.path, path: Data(changedFile.path.utf8))
        }
        resizeSeconds = benchmarkSeconds(since: resizeStart)
        resizeRefreshAttempts = attempts
        if node?.entry.metadata.logicalBytes != 8192 || summary.logicalBytes != unchanged.logicalBytes + 8160 || summary.nodeCount != unchanged.nodeCount {
            verificationFailures.append("Incremental refresh did not converge on the resized fixture file within 5 seconds")
            successfulResizeRefreshSeconds = nil
        } else {
            successfulResizeRefreshSeconds = attemptSeconds
        }
        resized = summary
    } else {
        resized = nil
        resizeSeconds = nil
        successfulResizeRefreshSeconds = nil
        resizeRefreshAttempts = nil
    }
    if full.metrics.contentBytesRead != 0 || unchanged.metrics.contentBytesRead != 0 || (resized?.metrics.contentBytesRead != nil && resized?.metrics.contentBytesRead != 0) {
        verificationFailures.append("Metadata scanning unexpectedly read file contents")
    }
    let cache: (logical: UInt64, allocated: UInt64) = try measureCache(database: database)
    #if DEBUG
    let buildConfiguration: String = "debug"
    #else
    let buildConfiguration: String = "release"
    #endif
    return BenchmarkReport(
        root: root.path, fixtureFiles: suppliedRoot == nil ? fileCount : nil, fixtureCreationSeconds: fixtureCreationSeconds,
        buildConfiguration: buildConfiguration,
        filesystemCacheState: suppliedRoot == nil
            ? "Warm OS filesystem caches; fixture files were just created; caches were not purged"
            : "Uncontrolled OS filesystem caches; caches were not purged",
        refreshConsistency: "FSEvents updates converge asynchronously; refresh is not an atomic live filesystem snapshot",
        fullScanSeconds: fullSeconds, fullScanNodesPerSecond: Double(full.nodeCount) / fullSeconds, fullScan: full,
        reopenAndQuerySeconds: reopenSeconds, freshProcessCachedQuerySeconds: processSeconds, cachedChildrenReturned: children.count,
        unchangedRefreshSeconds: unchangedSeconds, unchangedRefresh: unchanged,
        singleFileResizeConvergenceSeconds: resizeSeconds, singleFileResizeRefreshSeconds: successfulResizeRefreshSeconds,
        resizeRefreshAttempts: resizeRefreshAttempts, singleFileResize: resized,
        cacheLogicalBytes: cache.logical, cacheAllocatedBytes: cache.allocated, peakResidentBytes: try peakResidentBytes(),
        verificationFailures: verificationFailures
    )
}

private func createBenchmarkFixture(root: URL, fileCount: Int) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let content: Data = Data(repeating: 97, count: 4127)
    for number: Int in 0..<fileCount {
        let directory: URL = root.appendingPathComponent("group-\(number / 128)")
        if number % 128 == 0 { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try content.prefix(32 + number % 4096).write(to: directory.appendingPathComponent("file-\(number)"))
    }
}

private func readSummaryInFreshProcess(root: String, database: URL) throws -> IndexSummary {
    let process: Process = Process()
    let output: Pipe = Pipe()
    let diagnostic: Pipe = Pipe()
    let executable: String = CommandLine.arguments[0]
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["summary", root, "--cache", database.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = diagnostic
    try process.run()
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData: Data = diagnostic.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.processFailed(executable: executable, status: process.terminationStatus, stderr: String(decoding: errorData, as: UTF8.self))
    }
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(IndexSummary.self, from: data)
}

private func measureCache(database: URL) throws -> (logical: UInt64, allocated: UInt64) {
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    for suffix: String in ["", "-wal", "-shm"] {
        var metadata: stat = stat()
        guard stat(database.path + suffix, &metadata) == 0 else {
            if errno == ENOENT { continue }
            throw CLIError.resourceUsage(operation: "stat cache \(database.path + suffix)", code: errno)
        }
        logical += UInt64(metadata.st_size)
        allocated += UInt64(metadata.st_blocks) * 512
    }
    return (logical, allocated)
}

private func peakResidentBytes() throws -> UInt64 {
    var usage: rusage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CLIError.resourceUsage(operation: "getrusage", code: errno) }
    return UInt64(usage.ru_maxrss)
}

private func benchmarkSeconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed: Duration = start.duration(to: ContinuousClock.now)
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
}
