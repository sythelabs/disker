import Combine
import Foundation
import Sparkle
import SwiftUI

@main
struct DiskerApp: App {
    private let updaterController: SPUStandardUpdaterController
    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        WindowGroup {
            LaunchView(rootURL: rootURL, cacheURL: cacheURL, accessDirectory: accessDirectory)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
        }
    }

    private var accessDirectory: URL {
        #if DEBUG
        if let path: String = ProcessInfo.processInfo.environment["DISKER_PREVIEW_ACCESS_DIRECTORY"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
    }

    private var rootURL: URL {
        #if DEBUG
        if let path: String = ProcessInfo.processInfo.environment["DISKER_PREVIEW_ROOT"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var cacheURL: URL {
        #if DEBUG
        if let path: String = ProcessInfo.processInfo.environment["DISKER_PREVIEW_CACHE"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Disker/index.sqlite")
    }
}

private struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates: Bool = false

    var body: some View {
        Button("Check for Updates", action: updater.checkForUpdates)
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])) { available in
                canCheckForUpdates = available
            }
    }
}
