import Darwin
import Dispatch
import Foundation

public enum GitRepositoryKind: String, Codable, Equatable, Sendable {
    case repository
    case linkedWorktree
}

public struct GitRepositoryInfo: Codable, Equatable, Sendable {
    public let rootPath: String
    public let gitDirectoryPath: String
    public let commonDirectoryPath: String
    public let kind: GitRepositoryKind
    public let branch: String?
    public let head: String?
    public let lastCommitUnixSeconds: Int64?
    public let isDirty: Bool
}

public struct GitFileMetadata: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
}

public struct GitInputFile: Codable, Equatable, Sendable {
    public let path: String
    public let metadata: GitFileMetadata?
}

public struct GitInputFingerprint: Codable, Equatable, Sendable {
    public let rootPath: String
    public let files: [GitInputFile]
}

public enum GitInspectionError: Error, Sendable, CustomStringConvertible {
    case invalidPath(path: String)
    case launchFailed(executable: String, arguments: [String], diagnostic: String)
    case commandFailed(executable: String, arguments: [String], status: Int32, stderr: String)
    case timedOut(executable: String, arguments: [String], seconds: Int)
    case invalidOutput(arguments: [String], diagnostic: String)
    case invalidMetadata(path: String, diagnostic: String)
    case metadataFailed(path: String, code: Int32)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            return "Git inspection path does not exist: \(path)"
        case let .launchFailed(executable, arguments, diagnostic):
            return "Cannot launch Git: executable=\(executable), arguments=\(arguments), diagnostic=\(diagnostic)"
        case let .commandFailed(executable, arguments, status, stderr):
            return "Git command failed: executable=\(executable), arguments=\(arguments), status=\(status), stderr=\(stderr)"
        case let .timedOut(executable, arguments, seconds):
            return "Git command exceeded time limit: executable=\(executable), arguments=\(arguments), seconds=\(seconds)"
        case let .invalidOutput(arguments, diagnostic):
            return "Cannot parse Git output: arguments=\(arguments), diagnostic=\(diagnostic)"
        case let .invalidMetadata(path, diagnostic):
            return "Cannot parse Git metadata: path=\(path), diagnostic=\(diagnostic)"
        case let .metadataFailed(path, code):
            return "Cannot read Git metadata: path=\(path), errno=\(code), diagnostic=\(String(cString: strerror(code)))"
        }
    }
}

public struct GitInspector: Sendable {
    private let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public func inspect(path: String) throws -> GitRepositoryInfo? {
        let directory: URL = try inspectionDirectory(path: path)
        let rootPath: String
        do {
            rootPath = try queryPath(directory: directory, option: "--show-toplevel")
        } catch let error as GitInspectionError {
            if case let .commandFailed(_, _, status, stderr) = error,
               status == 128,
               stderr.hasPrefix("fatal: not a git repository ") {
                return nil
            }
            throw error
        }
        let gitDirectoryPath: String = try queryPath(directory: directory, option: "--git-dir")
        let commonDirectoryPath: String = try queryPath(directory: directory, option: "--git-common-dir")
        let statusArguments: [String] = commandArguments(directory: directory, command: [
            "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal",
            "--ignore-submodules=all", "--no-ahead-behind", "--no-renames"
        ])
        let status: GitStatusFields = try parseStatus(data: runCommand(arguments: statusArguments), arguments: statusArguments)
        let lastCommit: Int64?
        if status.head != nil {
            let logArguments: [String] = commandArguments(directory: directory, command: ["log", "-1", "--format=%ct", "HEAD", "--"])
            let logData: Data = try runCommand(arguments: logArguments)
            guard let text: String = String(data: logData, encoding: .utf8),
                  let timestamp: Int64 = Int64(removingFinalLineFeed(text)) else {
                throw GitInspectionError.invalidOutput(arguments: logArguments, diagnostic: "Expected a single committer UNIX timestamp")
            }
            lastCommit = timestamp
        } else {
            lastCommit = nil
        }
        return GitRepositoryInfo(
            rootPath: rootPath,
            gitDirectoryPath: gitDirectoryPath,
            commonDirectoryPath: commonDirectoryPath,
            kind: gitDirectoryPath == commonDirectoryPath ? .repository : .linkedWorktree,
            branch: status.branch,
            head: status.head,
            lastCommitUnixSeconds: lastCommit,
            isDirty: status.isDirty
        )
    }

    public func fingerprint(path: String) throws -> GitInputFingerprint? {
        var root: URL = try inspectionDirectory(path: path).resolvingSymlinksInPath()
        var marker: URL = root.appendingPathComponent(".git")
        var markerMetadata: GitFileMetadata? = try metadata(path: marker.path)
        while markerMetadata == nil {
            let parent: URL = root.deletingLastPathComponent()
            guard parent.path != root.path else { return nil }
            root = parent
            marker = root.appendingPathComponent(".git")
            markerMetadata = try metadata(path: marker.path)
        }
        var directoryFlag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path, isDirectory: &directoryFlag) else {
            throw GitInspectionError.invalidMetadata(path: marker.path, diagnostic: "Git marker disappeared while fingerprinting")
        }
        let gitDirectory: URL
        if directoryFlag.boolValue {
            gitDirectory = marker.resolvingSymlinksInPath()
        } else {
            let text: String = try readMetadata(path: marker.path)
            guard text.hasPrefix("gitdir: "), text.count > 8 else {
                throw GitInspectionError.invalidMetadata(path: marker.path, diagnostic: "Expected gitdir: path")
            }
            gitDirectory = resolveMetadataPath(String(text.dropFirst(8)), base: root)
        }
        let commonMarker: URL = gitDirectory.appendingPathComponent("commondir")
        let commonDirectory: URL
        if try metadata(path: commonMarker.path) != nil {
            commonDirectory = try resolveMetadataPath(readMetadata(path: commonMarker.path), base: gitDirectory)
        } else {
            commonDirectory = gitDirectory
        }
        let head: URL = gitDirectory.appendingPathComponent("HEAD")
        var paths: Set<String> = [
            marker.path, head.path, gitDirectory.appendingPathComponent("index").path,
            commonMarker.path, gitDirectory.appendingPathComponent("config.worktree").path,
            commonDirectory.appendingPathComponent("config").path,
            commonDirectory.appendingPathComponent("info/exclude").path,
            commonDirectory.appendingPathComponent("packed-refs").path,
            commonDirectory.appendingPathComponent("reftable/tables.list").path
        ]
        if try metadata(path: head.path) != nil {
            let text: String = try readMetadata(path: head.path)
            if text.hasPrefix("ref: ") {
                let reference: String = String(text.dropFirst(5))
                guard reference.hasPrefix("refs/"), !reference.split(separator: "/").contains("..") else {
                    throw GitInspectionError.invalidMetadata(path: head.path, diagnostic: "HEAD contains an invalid reference path")
                }
                paths.insert(commonDirectory.appendingPathComponent(reference).path)
                paths.insert(gitDirectory.appendingPathComponent(reference).path)
            }
        }
        let files: [GitInputFile] = try paths.sorted().map { path in
            GitInputFile(path: path, metadata: try metadata(path: path))
        }
        return GitInputFingerprint(rootPath: root.path, files: files)
    }

    private func queryPath(directory: URL, option: String) throws -> String {
        let arguments: [String] = commandArguments(directory: directory, command: ["rev-parse", "--path-format=absolute", option])
        let data: Data = try runCommand(arguments: arguments)
        guard let text: String = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw GitInspectionError.invalidOutput(arguments: arguments, diagnostic: "Expected an absolute path")
        }
        let path: String = removingFinalLineFeed(text)
        guard path.hasPrefix("/") else {
            throw GitInspectionError.invalidOutput(arguments: arguments, diagnostic: "Expected an absolute path, received \(path)")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func commandArguments(directory: URL, command: [String]) -> [String] {
        ["--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "-C", directory.path] + command
    }

    private func runCommand(arguments: [String]) throws -> Data {
        let process: Process = Process()
        let output: Pipe = Pipe()
        let diagnostic: Pipe = Pipe()
        let buffer: GitProcessBuffer = GitProcessBuffer()
        let readers: DispatchGroup = DispatchGroup()
        let completion: DispatchSemaphore = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = diagnostic
        process.terminationHandler = { _ in completion.signal() }
        var environment: [String: String] = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw GitInspectionError.launchFailed(executable: executablePath, arguments: arguments, diagnostic: String(describing: error))
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            buffer.storeOutput(output.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            buffer.storeDiagnostic(diagnostic.fileHandleForReading.readDataToEndOfFile())
        }
        let deadline: DispatchTime = .now() + .seconds(30)
        guard completion.wait(timeout: deadline) == .success,
              readers.wait(timeout: deadline) == .success else {
            if process.isRunning {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw GitInspectionError.timedOut(executable: executablePath, arguments: arguments, seconds: 30)
        }
        let result: GitCommandOutput = buffer.result()
        guard process.terminationStatus == 0 else {
            throw GitInspectionError.commandFailed(executable: executablePath, arguments: arguments, status: process.terminationStatus, stderr: String(decoding: result.diagnostic, as: UTF8.self))
        }
        return result.output
    }
}

private struct GitStatusFields {
    let branch: String?
    let head: String?
    let isDirty: Bool
}

private struct GitCommandOutput {
    let output: Data
    let diagnostic: Data
}

private final class GitProcessBuffer: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var output: Data = Data()
    private var diagnostic: Data = Data()

    func storeOutput(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        output = data
    }

    func storeDiagnostic(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        diagnostic = data
    }

    func result() -> GitCommandOutput {
        lock.lock()
        defer { lock.unlock() }
        return GitCommandOutput(output: output, diagnostic: diagnostic)
    }
}

private func parseStatus(data: Data, arguments: [String]) throws -> GitStatusFields {
    var branch: String?
    var head: String?
    var foundBranch: Bool = false
    var foundHead: Bool = false
    var dirty: Bool = false
    for record: Data.SubSequence in data.split(separator: 0) {
        if record.starts(with: Data("# branch.oid ".utf8)) {
            guard let value: String = String(data: Data(record.dropFirst(13)), encoding: .utf8),
                  value == "(initial)" || ((value.count == 40 || value.count == 64) && value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })) else {
                throw GitInspectionError.invalidOutput(arguments: arguments, diagnostic: "Expected branch.oid commit ID or (initial)")
            }
            head = value == "(initial)" ? nil : value
            foundHead = true
        } else if record.starts(with: Data("# branch.head ".utf8)) {
            guard let value: String = String(data: Data(record.dropFirst(14)), encoding: .utf8), !value.isEmpty else {
                throw GitInspectionError.invalidOutput(arguments: arguments, diagnostic: "Expected branch.head name or (detached)")
            }
            branch = value == "(detached)" ? nil : value
            foundBranch = true
        } else if record.first != UInt8(ascii: "#") {
            dirty = true
        }
    }
    guard foundBranch, foundHead else {
        throw GitInspectionError.invalidOutput(arguments: arguments, diagnostic: "Missing branch.oid or branch.head headers")
    }
    return GitStatusFields(branch: branch, head: head, isDirty: dirty)
}

private func inspectionDirectory(path: String) throws -> URL {
    var directoryFlag: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directoryFlag) else {
        throw GitInspectionError.invalidPath(path: path)
    }
    let url: URL = URL(fileURLWithPath: path).standardizedFileURL
    return directoryFlag.boolValue ? url : url.deletingLastPathComponent()
}

private func removingFinalLineFeed(_ text: String) -> String {
    text.hasSuffix("\n") ? String(text.dropLast()) : text
}

private func resolveMetadataPath(_ path: String, base: URL) -> URL {
    let url: URL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    return url.standardizedFileURL.resolvingSymlinksInPath()
}

private func readMetadata(path: String) throws -> String {
    let descriptor: Int32 = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        let code: Int32 = errno
        throw GitInspectionError.invalidMetadata(path: path, diagnostic: "open failed: errno=\(code), diagnostic=\(String(cString: strerror(code)))")
    }
    defer { _ = close(descriptor) }
    var opened: stat = stat()
    guard fstat(descriptor, &opened) == 0 else {
        let code: Int32 = errno
        throw GitInspectionError.invalidMetadata(path: path, diagnostic: "fstat failed: errno=\(code), diagnostic=\(String(cString: strerror(code)))")
    }
    guard opened.st_mode & S_IFMT == S_IFREG else {
        throw GitInspectionError.invalidMetadata(path: path, diagnostic: "Expected a regular file for Git metadata")
    }
    let file: FileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data: Data
    do {
        data = try file.read(upToCount: 65_537) ?? Data()
    } catch {
        throw GitInspectionError.invalidMetadata(path: path, diagnostic: String(describing: error))
    }
    guard data.count <= 65_536, let text: String = String(data: data, encoding: .utf8), !text.isEmpty else {
        throw GitInspectionError.invalidMetadata(path: path, diagnostic: "Expected nonempty UTF-8 metadata no larger than 65536 bytes")
    }
    let value: String = removingFinalLineFeed(text)
    guard !value.isEmpty else {
        throw GitInspectionError.invalidMetadata(path: path, diagnostic: "Expected a nonempty metadata value")
    }
    return value
}

private func metadata(path: String) throws -> GitFileMetadata? {
    var value: stat = stat()
    guard stat(path, &value) == 0 else {
        let code: Int32 = errno
        if code == ENOENT || code == ENOTDIR { return nil }
        throw GitInspectionError.metadataFailed(path: path, code: code)
    }
    return GitFileMetadata(
        device: UInt64(UInt32(bitPattern: value.st_dev)),
        inode: UInt64(value.st_ino), size: value.st_size,
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
        changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
    )
}
