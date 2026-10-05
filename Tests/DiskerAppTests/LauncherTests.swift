import Foundation
import Testing

@Suite("Development launcher")
struct LauncherTests {
    @Test func runRequestsAFreshApplicationInstance() throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-launcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        let recorder: URL = fixture.appendingPathComponent("open")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$DISKER_LAUNCH_ARGUMENTS\"\n".utf8).write(to: recorder)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
        let argumentsFile: URL = fixture.appendingPathComponent("arguments")
        let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner: Process = Process()
        runner.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        runner.arguments = ["just", "--justfile", root.appendingPathComponent("justfile").path, "--no-deps", "run"]
        var environment: [String: String] = ProcessInfo.processInfo.environment
        let path: String = try #require(environment["PATH"])
        environment["PATH"] = fixture.path + ":" + path
        environment["DISKER_LAUNCH_ARGUMENTS"] = argumentsFile.path
        runner.environment = environment
        runner.standardOutput = FileHandle.nullDevice
        runner.standardError = FileHandle.nullDevice
        try runner.run()
        runner.waitUntilExit()
        #expect(runner.terminationStatus == 0)
        let arguments: [String] = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.contains("-n"), "Reusing an existing app process shows its old UI after rebuilding")
        #expect(arguments.contains(".build/Disker.app"))
    }
}
