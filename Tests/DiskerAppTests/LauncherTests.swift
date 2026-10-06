import Foundation
import Testing

@Suite("Development launcher")
struct LauncherTests {
    @Test func rebundlingReplacesReadOnlyResourcesAndRemovesObsoleteFiles() throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-bundle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name: String in ["justfile", "Info.plist", "Resources"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: fixture.appendingPathComponent(name))
        }
        let bin: URL = fixture.appendingPathComponent("bin")
        let resource: URL = bin.appendingPathComponent("Fixture.bundle/PrivacyInfo.xcprivacy")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: resource)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: resource.path)
        try Data("executable".utf8).write(to: bin.appendingPathComponent("Disker"))
        let tools: URL = fixture.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for (name, script): (String, String) in [
            ("xcrun", "#!/bin/sh\nprintf '%s\\n' '<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>' > .build/app-icon-info.plist\n"),
            ("codesign", "#!/bin/sh\nexit 0\n")
        ] {
            let tool: URL = tools.appendingPathComponent(name)
            try Data(script.utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let obsolete: URL = fixture.appendingPathComponent(".build/Disker.app/Contents/Resources/obsolete")
        for generation: Int in 1...2 {
            let runner: Process = Process()
            runner.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            runner.arguments = ["just", "--justfile", fixture.appendingPathComponent("justfile").path, "_bundle", bin.appendingPathComponent("Disker").path]
            var environment: [String: String] = ProcessInfo.processInfo.environment
            let path: String = try #require(environment["PATH"])
            environment["PATH"] = tools.path + ":" + path
            runner.environment = environment
            runner.standardOutput = FileHandle.nullDevice
            runner.standardError = FileHandle.nullDevice
            try runner.run()
            runner.waitUntilExit()
            #expect(runner.terminationStatus == 0, "Bundle generation \(generation) must succeed with read-only package resources")
            if generation == 1 {
                try Data("obsolete".utf8).write(to: obsolete)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: resource.path)
                try Data("second".utf8).write(to: resource)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: resource.path)
            }
        }
        let bundled: URL = fixture.appendingPathComponent(".build/Disker.app/Contents/Resources/Fixture.bundle/PrivacyInfo.xcprivacy")
        #expect(try String(contentsOf: bundled, encoding: .utf8) == "second")
        #expect(!FileManager.default.fileExists(atPath: obsolete.path))
    }

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
