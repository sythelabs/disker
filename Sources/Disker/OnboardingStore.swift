import Darwin
import Foundation
import GRDB

actor OnboardingStore {
    private let database: DatabaseQueue

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration: Configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous=FULL") }
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        }
    }

    func isComplete() throws -> Bool {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = 'onboarding_version'") == 1
        }
    }

    func complete() throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO app_settings(key, value) VALUES ('onboarding_version', 1) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        }
    }
}

enum DiskAccessStatus: Equatable, Sendable {
    case checking
    case allowed
    case denied
    case unavailable(path: String, code: Int32)

    var message: String {
        switch self {
        case .checking: return "Checking protected folder access"
        case .allowed: return "Protected folders are readable"
        case .denied: return "Enable Full Disk Access, then quit and reopen Disker"
        case .unavailable(let path, let code): return "Could not check access to \(path): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

func checkDiskAccess(directory: URL) -> DiskAccessStatus {
    // Opening this protected directory checks access without reading or querying TCC.db.
    guard let handle: UnsafeMutablePointer<DIR> = opendir(directory.path) else {
        let code: Int32 = errno
        if code == EPERM || code == EACCES { return .denied }
        return .unavailable(path: directory.path, code: code)
    }
    guard closedir(handle) == 0 else { return .unavailable(path: directory.path, code: errno) }
    return .allowed
}

func canStartDisker(onboardingComplete: Bool, access: DiskAccessStatus) -> Bool {
    onboardingComplete && access == .allowed
}
