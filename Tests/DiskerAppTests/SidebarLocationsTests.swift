import Foundation
import Testing
@testable import Disker

private struct SidebarFixture {
    let root: URL
    let folder: URL
    let defaults: UserDefaults
    let suiteName: String
}

private func sidebarFixture() throws -> SidebarFixture {
    let suiteName: String = "disker-sidebar-" + UUID().uuidString
    let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    let folder: URL = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let defaults: UserDefaults = try #require(UserDefaults(suiteName: suiteName))
    return SidebarFixture(root: root, folder: folder, defaults: defaults, suiteName: suiteName)
}

private func removeSidebarFixture(_ fixture: SidebarFixture) {
    fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    do { try FileManager.default.removeItem(at: fixture.root) }
    catch { Issue.record(error) }
}

@Suite("Sidebar locations")
@MainActor struct SidebarLocationsTests {
    @Test func folderStarsPersistWithoutTouchingUnavailableFolders() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.star(fixture.folder)
        try FileManager.default.removeItem(at: fixture.folder)
        let restored: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        #expect(restored.starred.count == 1)
        #expect(restored.starred.first?.url.path == fixture.folder.path)
        #expect(restored.isStarred(fixture.folder))
    }

    @Test func equivalentURLSpellingsProduceOneStar() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        let dotted: URL = fixture.folder.appendingPathComponent("..").appendingPathComponent("folder")
        try await model.star(dotted)
        try await model.star(URL(fileURLWithPath: fixture.folder.path, isDirectory: false))
        #expect(model.starred.count == 1)
        #expect(model.isStarred(fixture.folder))
    }

    @Test func removingAStarUpdatesPersistedState() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.star(fixture.folder)
        model.unstar(fixture.folder)
        #expect(!model.isStarred(fixture.folder))
        #expect(SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults).starred.isEmpty)
    }

    @Test func ordinaryFoldersAreStarredWithoutGitMetadata() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.star(fixture.folder)
        #expect(model.isStarred(fixture.folder))
        #expect(model.starred.first?.title == "folder")
    }

    @Test func filesFailExplicitlyAndAreNeverPersisted() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let file: URL = fixture.root.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        await #expect(throws: SidebarLocationError.notFolder(file.path)) {
            try await model.star(file)
        }
        #expect(model.starred.isEmpty)
        #expect(SidebarLocationError.notFolder(file.path).errorDescription?.contains("Only folders can be starred") == true)
        #expect(SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults).starred.isEmpty)
    }

    @Test func symlinkAliasesKeepTheirOwnPathIdentity() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let alias: URL = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.folder)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.star(fixture.folder)
        try await model.star(alias)
        #expect(Set(model.starred.map(\.id)) == Set([fixture.folder.path, alias.path]))
    }

    @Test func unavailableFoldersAndBrokenLinksFailWithTheirOriginalPaths() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let missing: URL = fixture.root.appendingPathComponent("missing")
        let broken: URL = fixture.root.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        for url in [missing, broken] {
            do {
                try await model.star(url)
                Issue.record("An unavailable folder was starred: \(url.path)")
            } catch SidebarLocationError.folderUnavailable(let path, let reason) {
                #expect(path == url.path)
                #expect(!reason.isEmpty)
            } catch { Issue.record(error) }
        }
        #expect(model.starred.isEmpty)
    }

    @Test func volumeLocationsSeparateNetworkFromLocalAndAlwaysIncludeHome() {
        let home: URL = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let localDisk: URL = URL(fileURLWithPath: "/", isDirectory: true)
        let networkDisk: URL = URL(fileURLWithPath: "/Volumes/Shared", isDirectory: true)
        let volumes: [SidebarVolume] = [
            SidebarVolume(url: networkDisk, title: "Shared", isLocal: false),
            SidebarVolume(url: localDisk, title: "Macintosh HD", isLocal: true)
        ]
        let result: SidebarVolumePartition = partitionSidebarVolumes(volumes, homeURL: home)
        #expect(result.local.map(\.id) == [home.path, localDisk.path])
        #expect(result.local.first?.systemImage == "house")
        #expect(result.network.map(\.id) == [networkDisk.path])
        #expect(result.network.first?.systemImage == "network")
    }
}
