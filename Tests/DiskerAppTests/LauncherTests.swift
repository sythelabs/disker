import AppKit
import Foundation
import Testing
@testable import Disker

@Suite("Development launcher")
struct LauncherTests {
    @Test @MainActor func rebundlingReplacesReadOnlyResourcesAndRemovesObsoleteFiles() throws {
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
        let framework: URL = fixture.appendingPathComponent(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
        let frameworkBinary: URL = framework.appendingPathComponent("Versions/B/Sparkle")
        try FileManager.default.createDirectory(at: frameworkBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("license".utf8).write(to: fixture.appendingPathComponent(".build/artifacts/sparkle/Sparkle/LICENSE"))
        try Data("framework".utf8).write(to: frameworkBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: frameworkBinary.path)
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "B")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Sparkle").path, withDestinationPath: "Versions/Current/Sparkle")
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
        let embedded: URL = fixture.appendingPathComponent(".build/Disker.app/Contents/Frameworks/Sparkle.framework/Sparkle")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: embedded.path) == "Versions/Current/Sparkle")
        #expect(FileManager.default.isExecutableFile(atPath: embedded.path))
        #expect(try String(contentsOf: embedded, encoding: .utf8) == "framework")
        #expect(try String(contentsOf: fixture.appendingPathComponent(".build/Disker.app/Contents/Resources/Sparkle-LICENSE.txt"), encoding: .utf8) == "license")
        let appBundle: Bundle = try #require(Bundle(url: fixture.appendingPathComponent(".build/Disker.app")))
        let mouse: NSImage = try loadOnboardingMouse(bundle: appBundle)
        #expect(mouse.size.width == 1024)
        #expect(mouse.size.height == 1024)
    }

    @Test @MainActor func mouseArtworkReportsMissingAndInvalidResources() throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-artwork-" + UUID().uuidString + ".bundle")
        let resources: URL = fixture.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        let info: Data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.disker.artwork-tests", "CFBundlePackageType": "BNDL"], format: .xml, options: 0)
        try info.write(to: fixture.appendingPathComponent("Contents/Info.plist"))
        let bundle: Bundle = try #require(Bundle(url: fixture))
        #expect(throws: OnboardingArtworkError.missingResource) { try loadOnboardingMouse(bundle: bundle) }
        let invalidFixture: URL = fixture.appendingPathComponent("Invalid.bundle")
        let invalid: URL = invalidFixture.appendingPathComponent("Contents/Resources/DiskerMouse.png")
        try FileManager.default.createDirectory(at: invalid.deletingLastPathComponent(), withIntermediateDirectories: true)
        try info.write(to: invalidFixture.appendingPathComponent("Contents/Info.plist"))
        try Data("invalid image".utf8).write(to: invalid)
        let invalidBundle: Bundle = try #require(Bundle(url: invalidFixture))
        #expect(throws: OnboardingArtworkError.unreadableResource(invalid.path)) { try loadOnboardingMouse(bundle: invalidBundle) }
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
