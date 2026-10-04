import Darwin
import Dispatch
import Foundation
import Testing
@testable import DiskerCore

@Suite("Git inspection")
struct GitInspectorTests {
    @Test("Ordinary directories are not repositories")
    func ordinaryDirectory() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "ordinary")
        defer { removeGitFixtureDirectory(directory) }
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")

        #expect(try inspector.inspect(path: directory.path) == nil)
        #expect(try inspector.fingerprint(path: directory.path) == nil)
    }

    @Test("Repository metadata and filesystem edit times remain separate")
    func repositoryMetadata() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "repository")
        defer { removeGitFixtureDirectory(directory) }
        try initializeGitFixture(at: directory)
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let info: GitRepositoryInfo = try #require(try inspector.inspect(path: directory.path))

        #expect(info.kind == .repository)
        #expect(info.rootPath == directory.resolvingSymlinksInPath().path)
        #expect(info.gitDirectoryPath == info.commonDirectoryPath)
        #expect(info.branch == "main")
        #expect(info.head?.count == 40)
        #expect(info.lastCommitUnixSeconds == 1_700_000_000)
        #expect(!info.isDirty)
    }

    @Test("Linked worktrees use distinct per-worktree and common directories")
    func linkedWorktree() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "linked")
        defer { removeGitFixtureDirectory(directory) }
        let repository: URL = directory.appendingPathComponent("main")
        let linked: URL = directory.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try initializeGitFixture(at: repository)
        _ = try runGitFixture(at: repository, arguments: ["worktree", "add", "-b", "feature", linked.path])
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let info: GitRepositoryInfo = try #require(try inspector.inspect(path: linked.path))

        #expect(info.kind == .linkedWorktree)
        #expect(info.branch == "feature")
        #expect(info.rootPath == linked.resolvingSymlinksInPath().path)
        #expect(info.gitDirectoryPath != info.commonDirectoryPath)
        #expect(info.commonDirectoryPath == repository.appendingPathComponent(".git").resolvingSymlinksInPath().path)
        #expect(try inspector.fingerprint(path: linked.path) != nil)
    }

    @Test("A gitfile for a separate Git directory is not a linked worktree")
    func separateGitDirectory() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "separate")
        defer { removeGitFixtureDirectory(directory) }
        let repository: URL = directory.appendingPathComponent("repository")
        let gitDirectory: URL = directory.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try runGitFixture(at: repository, arguments: ["init", "--initial-branch=main", "--separate-git-dir", gitDirectory.path])
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let info: GitRepositoryInfo = try #require(try inspector.inspect(path: repository.path))

        #expect(info.kind == .repository)
        #expect(info.gitDirectoryPath == info.commonDirectoryPath)
        #expect(info.head == nil)
        #expect(info.lastCommitUnixSeconds == nil)
    }

    @Test("Detached and unborn HEAD have explicit optional fields")
    func detachedAndUnborn() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "head")
        defer { removeGitFixtureDirectory(directory) }
        _ = try runGitFixture(at: directory, arguments: ["init", "--initial-branch=main"])
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let unborn: GitRepositoryInfo = try #require(try inspector.inspect(path: directory.path))
        #expect(unborn.branch == "main")
        #expect(unborn.head == nil)
        #expect(unborn.lastCommitUnixSeconds == nil)

        try createGitFixtureCommit(at: directory)
        _ = try runGitFixture(at: directory, arguments: ["checkout", "--detach"])
        let detached: GitRepositoryInfo = try #require(try inspector.inspect(path: directory.path))
        #expect(detached.branch == nil)
        #expect(detached.head != nil)
        #expect(detached.lastCommitUnixSeconds == 1_700_000_000)
    }

    @Test("Dirty inspection does not rewrite the Git index")
    func dirtyAndReadOnlyIndex() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "dirty")
        defer { removeGitFixtureDirectory(directory) }
        try initializeGitFixture(at: directory)
        let index: URL = directory.appendingPathComponent(".git/index")
        let before: Data = try Data(contentsOf: index)
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let beforeMetadata: GitFileMetadata? = try inspector.fingerprint(path: directory.path)?.files.first { $0.path == index.path }?.metadata
        try Data("changed\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try Data("untracked\n".utf8).write(to: directory.appendingPathComponent("new file\nname.txt"))
        let info: GitRepositoryInfo = try #require(try inspector.inspect(path: directory.path))
        let afterMetadata: GitFileMetadata? = try inspector.fingerprint(path: directory.path)?.files.first { $0.path == index.path }?.metadata

        #expect(info.isDirty)
        #expect(try Data(contentsOf: index) == before)
        #expect(beforeMetadata != nil)
        #expect(afterMetadata == beforeMetadata)
    }

    @Test("Paths with spaces and line feeds are preserved")
    func unusualPaths() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "space and\nnewline")
        defer { removeGitFixtureDirectory(directory) }
        try initializeGitFixture(at: directory)
        let nested: URL = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let info: GitRepositoryInfo = try #require(try inspector.inspect(path: nested.path))

        #expect(info.rootPath == directory.resolvingSymlinksInPath().path)
        #expect(info.gitDirectoryPath == directory.appendingPathComponent(".git").resolvingSymlinksInPath().path)
    }

    @Test("Git fingerprints change when refs or the index change")
    func metadataFingerprint() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "fingerprint")
        defer { removeGitFixtureDirectory(directory) }
        try initializeGitFixture(at: directory)
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")
        let before: GitInputFingerprint = try #require(try inspector.fingerprint(path: directory.path))
        try Data("changed\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
        _ = try runGitFixture(at: directory, arguments: ["add", "file.txt"])
        let staged: GitInputFingerprint = try #require(try inspector.fingerprint(path: directory.path))
        #expect(staged != before)

        _ = try runGitFixture(at: directory, arguments: ["commit", "-m", "second"])
        let committed: GitInputFingerprint = try #require(try inspector.fingerprint(path: directory.path))
        #expect(committed != staged)
        #expect(try inspector.fingerprint(path: directory.path) == committed)
    }

    @Test("Git errors retain the command, status, and diagnostic")
    func commandFailure() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "failure")
        defer { removeGitFixtureDirectory(directory) }
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/false")

        do {
            _ = try inspector.inspect(path: directory.path)
            Issue.record("Expected a Git command failure")
        } catch let error as GitInspectionError {
            guard case let .commandFailed(executable, arguments, status, _) = error else {
                Issue.record("Expected a command failure, received \(error)")
                return
            }
            #expect(executable == "/usr/bin/false")
            #expect(arguments.contains("rev-parse"))
            #expect(status == 1)
        }
    }

    @Test("Launch failures are distinct from command failures")
    func launchFailure() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "launch")
        defer { removeGitFixtureDirectory(directory) }
        let inspector: GitInspector = GitInspector(executablePath: directory.appendingPathComponent("missing-git").path)

        do {
            _ = try inspector.inspect(path: directory.path)
            Issue.record("Expected a Git launch failure")
        } catch let error as GitInspectionError {
            guard case let .launchFailed(executable, arguments, diagnostic) = error else {
                Issue.record("Expected a launch failure, received \(error)")
                return
            }
            #expect(executable.hasSuffix("missing-git"))
            #expect(arguments.contains("rev-parse"))
            #expect(!diagnostic.isEmpty)
        }
    }

    @Test("Nonregular Git metadata is rejected", arguments: [".git", ".git/HEAD", ".git/commondir"])
    func nonregularMetadata(relativePath: String) async throws {
        let directory: URL = try makeGitFixtureDirectory(name: "special-metadata")
        defer { removeGitFixtureDirectory(directory) }
        if relativePath != ".git" { try initializeGitFixture(at: directory) }
        let special: URL = directory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: special.path) { try FileManager.default.removeItem(at: special) }
        try #require(mkfifo(special.path, 0o600) == 0)
        let keeper: Int32 = open(special.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(keeper >= 0)
        let payload: Data = Data("invalid-but-readable\n".utf8)
        let written: Int = payload.withUnsafeBytes { write(keeper, $0.baseAddress, $0.count) }
        try #require(written == payload.count)
        let released: Task<Void, Never> = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                Issue.record(error)
            }
            if close(keeper) != 0 { Issue.record("Cannot close Git metadata FIFO keeper: \(errno)") }
        }
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")

        do {
            _ = try inspector.fingerprint(path: directory.path)
            Issue.record("Expected nonregular metadata to be rejected: \(special.path)")
        } catch let error as GitInspectionError {
            guard case let .invalidMetadata(path, diagnostic) = error else {
                Issue.record("Expected invalid metadata, received \(error)")
                return
            }
            #expect(path == special.resolvingSymlinksInPath().path)
            #expect(diagnostic.contains("regular file"))
        }
        await released.value
    }

    @Test("Symlinks to regular Git metadata remain readable")
    func regularMetadataSymlink() throws {
        let directory: URL = try makeGitFixtureDirectory(name: "metadata-symlink")
        defer { removeGitFixtureDirectory(directory) }
        try initializeGitFixture(at: directory)
        let head: URL = directory.appendingPathComponent(".git/HEAD")
        let target: URL = directory.appendingPathComponent(".git/head-target")
        try FileManager.default.moveItem(at: head, to: target)
        try FileManager.default.createSymbolicLink(at: head, withDestinationURL: target)
        let inspector: GitInspector = GitInspector(executablePath: "/usr/bin/git")

        #expect(try inspector.fingerprint(path: directory.path) != nil)
    }
}

private func makeGitFixtureDirectory(name: String) throws -> URL {
    let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-git-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func initializeGitFixture(at directory: URL) throws {
    _ = try runGitFixture(at: directory, arguments: ["init", "--initial-branch=main"])
    try createGitFixtureCommit(at: directory)
}

private func createGitFixtureCommit(at directory: URL) throws {
    _ = try runGitFixture(at: directory, arguments: ["config", "user.name", "Disker Tests"])
    _ = try runGitFixture(at: directory, arguments: ["config", "user.email", "disker@example.test"])
    try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
    _ = try runGitFixture(at: directory, arguments: ["add", "file.txt"])
    _ = try runGitFixture(at: directory, arguments: ["commit", "-m", "fixture"])
}

private func runGitFixture(at directory: URL, arguments: [String]) throws -> Data {
    let process: Process = Process()
    let output: Pipe = Pipe()
    let diagnostic: Pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = directory
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = diagnostic
    var environment: [String: String] = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_AUTHOR_DATE"] = "1700000000 +0000"
    environment["GIT_COMMITTER_DATE"] = "1700000000 +0000"
    process.environment = environment
    try process.run()
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData: Data = diagnostic.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitInspectionError.commandFailed(executable: "/usr/bin/git", arguments: arguments, status: process.terminationStatus, stderr: String(decoding: errorData, as: UTF8.self))
    }
    return data
}

private func removeGitFixtureDirectory(_ directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        Issue.record("Cannot remove Git fixture at \(directory.path): \(error)")
    }
}
