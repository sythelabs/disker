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
    @Test func favoritesPersistWithoutTouchingUnavailableFolders() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.addFavorites([fixture.folder], at: model.favorites.count)
        try FileManager.default.removeItem(at: fixture.folder)
        let restored: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        #expect(restored.favorites.count == 6)
        #expect(restored.favorites.last?.url.path == fixture.folder.path)
        #expect(restored.isFavorite(fixture.folder))
    }

    @Test func equivalentURLSpellingsProduceOneFavorite() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        let dotted: URL = fixture.folder.appendingPathComponent("..").appendingPathComponent("folder")
        try await model.addFavorites([dotted], at: model.favorites.count)
        try await model.addFavorites([URL(fileURLWithPath: fixture.folder.path, isDirectory: false)], at: model.favorites.count)
        #expect(model.favorites.count == 6)
        #expect(model.isFavorite(fixture.folder))
    }

    @Test func removingAFavoriteUpdatesPersistedState() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.addFavorites([fixture.folder], at: model.favorites.count)
        model.removeFavorite(fixture.folder)
        #expect(!model.isFavorite(fixture.folder))
        #expect(!SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults).isFavorite(fixture.folder))
    }

    @Test func ordinaryFoldersAreFavoritesWithoutGitMetadata() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.addFavorites([fixture.folder], at: model.favorites.count)
        #expect(model.isFavorite(fixture.folder))
        #expect(model.favorites.last?.title == "folder")
    }

    @Test func filesFailExplicitlyAndAreNeverPersisted() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let file: URL = fixture.root.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        await #expect(throws: SidebarLocationError.notFolder(file.path)) {
            try await model.addFavorites([file], at: model.favorites.count)
        }
        #expect(!model.isFavorite(file))
        #expect(SidebarLocationError.notFolder(file.path).errorDescription?.contains("Only folders can be added to Favorites") == true)
        #expect(!SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults).isFavorite(file))
    }

    @Test func symlinkAliasesKeepTheirOwnPathIdentity() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let alias: URL = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.folder)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.addFavorites([fixture.folder], at: model.favorites.count)
        try await model.addFavorites([alias], at: model.favorites.count)
        #expect(model.favorites.suffix(2).map(\.id) == [fixture.folder.path, alias.path])
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
                try await model.addFavorites([url], at: model.favorites.count)
                Issue.record("An unavailable folder was added to Favorites: \(url.path)")
            } catch SidebarLocationError.folderUnavailable(let path, let reason) {
                #expect(path == url.path)
                #expect(!reason.isEmpty)
            } catch { Issue.record(error) }
        }
        #expect(model.favorites.count == 5)
    }

    @Test func previousStarredFoldersMigrateIntoFavorites() throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        fixture.defaults.set([fixture.folder.path], forKey: "sidebar.starredFolders")
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        #expect(model.favorites.last?.id == fixture.folder.path)
        model.removeFavorite(fixture.folder)
        #expect(!SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults).isFavorite(fixture.folder))
    }

    @Test func folderDropsInsertAtTheRequestedPositionAndDeduplicate() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let second: URL = fixture.root.appendingPathComponent("another folder")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        try await model.addFavorites([fixture.folder, second, fixture.folder], at: 1)
        #expect(model.favorites[1].id == fixture.folder.path)
        #expect(model.favorites[2].id == second.path)
        #expect(model.favorites.count == 7)
        let restored: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        #expect(restored.favorites == model.favorites)
    }

    @Test func anInvalidDropDoesNotPartiallyPinFolders() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let file: URL = fixture.root.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        let original: [SidebarLocation] = model.favorites
        await #expect(throws: SidebarLocationError.notFolder(file.path)) {
            try await model.addFavorites([fixture.folder, file], at: 0)
        }
        #expect(model.favorites == original)
        #expect(SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults).favorites == original)
    }

    @Test func webURLsCannotPinMatchingLocalPaths() async throws {
        let fixture: SidebarFixture = try sidebarFixture()
        defer { removeSidebarFixture(fixture) }
        let model: SidebarLocations = SidebarLocations(homeURL: fixture.root, defaults: fixture.defaults)
        let url: URL = try #require(URL(string: "https://example.com" + fixture.folder.path))
        await #expect(throws: FileOperationError.failed("Read path", url, "Expected a file URL")) {
            try await model.addFavorites([url], at: 0)
        }
        #expect(!model.isFavorite(fixture.folder))
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
