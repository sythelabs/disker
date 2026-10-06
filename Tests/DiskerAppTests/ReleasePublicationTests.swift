import CryptoKit
import Foundation
import Testing

@Suite("Release publication")
struct ReleasePublicationTests {
    @Test func publishesADraftBeforeItsTagExists() throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-publish-" + UUID().uuidString)
        let dist: URL = fixture.appendingPathComponent("dist")
        let tools: URL = fixture.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        var checksums: [String] = []
        for name: String in ["Disker-0.1.5-macOS-universal.zip", "appcast.xml"] {
            let data: Data = Data(name.utf8)
            try data.write(to: dist.appendingPathComponent(name))
            let digest: String = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            checksums.append(digest + "  " + name)
        }
        try Data((checksums.joined(separator: "\n") + "\n").utf8).write(to: dist.appendingPathComponent("SHA256SUMS.txt"))
        let ghScript: String = """
        #!/bin/sh
        case "$1 $2" in
          'release create') touch "$DISKER_DRAFT_CREATED"; exit 0 ;;
          'release view') test -f "$DISKER_DRAFT_CREATED" || exit 1; printf '%s\\n' 12345; exit 0 ;;
          'api --method')
            test "$3" = PATCH && test "$4" = repos/sythelabs/disker/releases/12345 || exit 1
            test -f "$DISKER_DRAFT_CREATED" || exit 1
            touch "$DISKER_DRAFT_PUBLISHED"; exit 0 ;;
          *) printf '%s\\n' 'Not Found (HTTP 404): a draft has no published tag endpoint' >&2; exit 1 ;;
        esac
        """
        for (name, script): (String, String) in [
            ("gh", ghScript),
            ("sha256sum", "#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n")
        ] {
            let file: URL = tools.appendingPathComponent(name)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workflow: String = try String(contentsOf: root.appendingPathComponent(".github/workflows/build.yml"), encoding: .utf8)
        let publication: String = try #require(workflow.components(separatedBy: "      - name: Publish the versioned build\n").last)
        let commands: String = try #require(publication.components(separatedBy: "        run: |\n").last)
        let script: String = commands.split(separator: "\n").map { String($0.dropFirst(10)) }.joined(separator: "\n")
        let runner: Process = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = ["-e", "-c", script]
        runner.currentDirectoryURL = fixture
        var environment: [String: String] = ProcessInfo.processInfo.environment
        environment["PATH"] = tools.path + ":" + (try #require(environment["PATH"]))
        environment["GH_TOKEN"] = "fixture-token"
        environment["GH_REPO"] = "sythelabs/disker"
        environment["VERSION"] = "0.1.5"
        environment["COMMIT_SHA"] = String(repeating: "a", count: 40)
        environment["DISKER_DRAFT_CREATED"] = fixture.appendingPathComponent("created").path
        environment["DISKER_DRAFT_PUBLISHED"] = fixture.appendingPathComponent("published").path
        runner.environment = environment
        runner.standardOutput = FileHandle.nullDevice
        runner.standardError = FileHandle.nullDevice
        try runner.run()
        runner.waitUntilExit()
        #expect(runner.terminationStatus == 0, "Draft release lookup must work before GitHub publishes the tag")
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("published").path))
    }
}
