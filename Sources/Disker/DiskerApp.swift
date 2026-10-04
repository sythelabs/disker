import Foundation
import SwiftUI

@main
struct DiskerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(rootURL: rootURL, cacheURL: cacheURL)
        }
        .defaultSize(width: 1180, height: 720)
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
