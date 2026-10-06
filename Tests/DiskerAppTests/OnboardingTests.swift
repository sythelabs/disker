import Darwin
import Foundation
import Testing
@testable import Disker

@Suite("Onboarding")
struct OnboardingTests {
    @Test func completionSurvivesRelaunchAndIndexRemoval() async throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-onboarding-" + UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        let settings: URL = fixture.appendingPathComponent("settings.sqlite")
        let initial: OnboardingStore = try OnboardingStore(databaseURL: settings)
        #expect(try await !initial.isComplete())
        let interrupted: OnboardingStore = try OnboardingStore(databaseURL: settings)
        #expect(try await !interrupted.isComplete())
        try await initial.complete()
        try await initial.complete()
        let index: URL = fixture.appendingPathComponent("index.sqlite")
        try Data("replaceable index".utf8).write(to: index)
        try FileManager.default.removeItem(at: index)
        let reopened: OnboardingStore = try OnboardingStore(databaseURL: settings)
        #expect(try await reopened.isComplete())
    }

    @Test func settingsErrorsAreReported() throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-onboarding-invalid-" + UUID().uuidString)
        try Data("not a directory".utf8).write(to: fixture)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        #expect(throws: (any Error).self) { try OnboardingStore(databaseURL: fixture.appendingPathComponent("settings.sqlite")) }
    }

    @Test(arguments: [DiskAccessStatus.checking, .allowed, .denied, .unavailable(path: "/missing", code: ENOENT)])
    func scanRequiresCompletionAndCurrentAccess(access: DiskAccessStatus) {
        #expect(!canStartDisker(onboardingComplete: false, access: access))
        #expect(canStartDisker(onboardingComplete: true, access: access) == (access == .allowed))
    }

    @Test func accessProbeDoesNotCreateMissingDirectoriesOrReadContents() throws {
        let fixture: URL = FileManager.default.temporaryDirectory.appendingPathComponent("disker-onboarding-access-" + UUID().uuidString)
        #expect(checkDiskAccess(directory: fixture) == .unavailable(path: fixture.path, code: ENOENT))
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: fixture) }
            catch { Issue.record(error) }
        }
        let unreadable: URL = fixture.appendingPathComponent("unreadable")
        try Data("private contents".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        #expect(checkDiskAccess(directory: fixture) == .allowed)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.path)
        let denied: DiskAccessStatus = checkDiskAccess(directory: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        #expect(denied == .denied)
    }
}
