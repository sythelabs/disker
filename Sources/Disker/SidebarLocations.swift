import Darwin
import Foundation
import Observation

struct SidebarLocation: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let systemImage: String

    var id: String { url.path }
}

struct SidebarVolume: Sendable {
    let url: URL
    let title: String
    let isLocal: Bool
}

struct SidebarVolumePartition: Sendable {
    let local: [SidebarLocation]
    let network: [SidebarLocation]
}

enum SidebarLocationError: Error, LocalizedError, Equatable {
    case notFolder(String)
    case folderUnavailable(String, String)
    case mountedVolumesUnavailable
    case volumeMetadataUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notFolder(let path): return "Only folders can be starred. Select a folder instead of " + path
        case .folderUnavailable(let path, let reason): return "Could not access the folder at " + path + ": " + reason
        case .mountedVolumesUnavailable: return "Could not enumerate mounted volumes."
        case .volumeMetadataUnavailable(let path): return "Could not classify the mounted volume at " + path
        }
    }
}

func partitionSidebarVolumes(_ volumes: [SidebarVolume], homeURL: URL) -> SidebarVolumePartition {
    let home: URL = normalizedSidebarURL(homeURL)
    var seen: Set<String> = [home.path]
    var local: [SidebarLocation] = [SidebarLocation(url: home, title: home.lastPathComponent, systemImage: "house")]
    var network: [SidebarLocation] = []
    let sorted: [SidebarVolume] = volumes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    for volume in sorted {
        let url: URL = normalizedSidebarURL(volume.url)
        guard seen.insert(url.path).inserted else { continue }
        let location: SidebarLocation = SidebarLocation(url: url, title: volume.title, systemImage: volume.isLocal ? "internaldrive" : "network")
        if volume.isLocal { local.append(location) }
        else { network.append(location) }
    }
    return SidebarVolumePartition(local: local, network: network)
}

private func normalizedSidebarURL(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
}

private func mountedSidebarVolumes(homeURL: URL) throws -> SidebarVolumePartition {
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey]
    guard let urls: [URL] = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else {
        throw SidebarLocationError.mountedVolumesUnavailable
    }
    let volumes: [SidebarVolume] = try urls.map { url in
        let values: URLResourceValues = try url.resourceValues(forKeys: keys)
        guard let title: String = values.volumeName, let isLocal: Bool = values.volumeIsLocal else {
            throw SidebarLocationError.volumeMetadataUnavailable(url.path)
        }
        return SidebarVolume(url: url, title: title, isLocal: isLocal)
    }
    return partitionSidebarVolumes(volumes, homeURL: homeURL)
}

private func validateSidebarFolder(_ url: URL) throws {
    var metadata: stat = stat()
    let result: Int32 = url.path.withCString { stat($0, &metadata) }
    guard result == 0 else {
        let code: Int32 = errno
        throw SidebarLocationError.folderUnavailable(url.path, "stat error \(code): \(String(cString: strerror(code)))")
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else {
        throw SidebarLocationError.notFolder(url.path)
    }
}

@MainActor @Observable
final class SidebarLocations {
    private(set) var favorites: [SidebarLocation]
    private(set) var local: [SidebarLocation]
    private(set) var network: [SidebarLocation] = []
    private(set) var starred: [SidebarLocation]
    private(set) var errorMessage: String?
    @ObservationIgnored private let homeURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    private static let starredDefaultsKey: String = "sidebar.starredFolders"

    init(homeURL: URL, defaults: UserDefaults) {
        let home: URL = normalizedSidebarURL(homeURL)
        self.homeURL = home
        self.defaults = defaults
        favorites = [
            SidebarLocation(url: home.appendingPathComponent("Desktop", isDirectory: true), title: "Desktop", systemImage: "desktopcomputer"),
            SidebarLocation(url: home.appendingPathComponent("Documents", isDirectory: true), title: "Documents", systemImage: "doc"),
            SidebarLocation(url: home.appendingPathComponent("Downloads", isDirectory: true), title: "Downloads", systemImage: "arrow.down.circle"),
            SidebarLocation(url: home.appendingPathComponent("Pictures", isDirectory: true), title: "Pictures", systemImage: "photo"),
            SidebarLocation(url: URL(fileURLWithPath: "/Applications", isDirectory: true), title: "Applications", systemImage: "app.dashed")
        ]
        local = [SidebarLocation(url: home, title: home.lastPathComponent, systemImage: "house")]
        var seen: Set<String> = []
        starred = (defaults.stringArray(forKey: Self.starredDefaultsKey) ?? []).compactMap { path in
            let url: URL = normalizedSidebarURL(URL(fileURLWithPath: path, isDirectory: true))
            guard seen.insert(url.path).inserted else { return nil }
            return SidebarLocation(url: url, title: url.lastPathComponent, systemImage: "folder")
        }
    }

    func load() async {
        loadGeneration += 1
        let ticket: UInt64 = loadGeneration
        let home: URL = homeURL
        do {
            let volumes: SidebarVolumePartition = try await Task.detached(priority: .utility) { try mountedSidebarVolumes(homeURL: home) }.value
            guard ticket == loadGeneration else { return }
            local = volumes.local
            network = volumes.network
            errorMessage = nil
        } catch {
            if ticket == loadGeneration { errorMessage = error.localizedDescription }
        }
    }

    func star(_ url: URL) async throws {
        let folder: URL = normalizedSidebarURL(url)
        if isStarred(folder) { return }
        try await Task.detached(priority: .utility) { try validateSidebarFolder(folder) }.value
        if isStarred(folder) { return }
        starred.append(SidebarLocation(url: folder, title: folder.lastPathComponent, systemImage: "folder"))
        defaults.set(starred.map(\.id), forKey: Self.starredDefaultsKey)
    }

    func unstar(_ url: URL) {
        let id: String = normalizedSidebarURL(url).path
        starred.removeAll { $0.id == id }
        defaults.set(starred.map(\.id), forKey: Self.starredDefaultsKey)
    }

    func isStarred(_ url: URL) -> Bool {
        let id: String = normalizedSidebarURL(url).path
        return starred.contains { $0.id == id }
    }
}
