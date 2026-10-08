import CoreServices
import Darwin
import Foundation
import Synchronization

public struct JournalCheckpoint: Codable, Equatable, Sendable {
    public let journalID: String
    public let eventID: UInt64

    public init(journalID: String, eventID: UInt64) {
        self.journalID = journalID
        self.eventID = eventID
    }
}

public struct JournalReplay: Sendable {
    public let checkpoint: JournalCheckpoint?
    public let dirtyDirectories: [String]
    public let recursiveDirectories: [String]
    public let requiresFullScan: Bool
}

public enum FileEventJournalError: Error, Sendable {
    case filesystem(operation: String, path: String, code: Int32)
    case invalidPath(String)
    case streamCreation(String)
    case streamStart(String)
    case replayTimedOut(path: String, timeout: TimeInterval)
    case stopped(String)
}

struct JournalEvent: Sendable {
    let path: String
    let flags: UInt32
    let eventID: UInt64
}

struct JournalScopes: Sendable {
    let dirtyDirectories: [String]
    let recursiveDirectories: [String]
    let requiresFullScan: Bool
}

func reconciliationScopes(events: [JournalEvent], rootPath: String) -> JournalScopes {
    var dirty: Set<String> = []
    var recursive: Set<String> = []
    var full: Bool = false
    let unsafeFlags: UInt32 = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
    let treeFlags: UInt32 = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
    for event: JournalEvent in events {
        if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
        if event.flags & unsafeFlags != 0 { full = true; continue }
        guard isWithinRoot(path: event.path, rootPath: rootPath) else { full = true; continue }
        if event.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            recursive.insert(event.path)
            continue
        }
        let isDirectory: Bool = event.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let parent: String = event.path == rootPath ? rootPath : URL(fileURLWithPath: event.path).deletingLastPathComponent().path
        if isDirectory {
            dirty.insert(parent)
            if event.flags & treeFlags != 0 {
                recursive.insert(event.path)
            } else {
                dirty.insert(event.path)
            }
        } else if event.flags & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0 {
            dirty.insert(parent)
        } else {
            dirty.insert(event.path)
        }
    }
    return JournalScopes(dirtyDirectories: dirty.sorted(), recursiveDirectories: recursive.sorted(), requiresFullScan: full)
}

private func isWithinRoot(path: String, rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
}

private struct JournalIdentity {
    let device: dev_t
    let relativePath: String
    let journalID: String?
}

private func journalIdentity(rootPath: String) throws -> JournalIdentity {
    let descriptor: Int32 = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw FileEventJournalError.filesystem(operation: "open", path: rootPath, code: errno) }
    defer { close(descriptor) }
    var metadata: stat = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw FileEventJournalError.filesystem(operation: "fstat", path: rootPath, code: errno) }
    var filesystem: statfs = statfs()
    guard fstatfs(descriptor, &filesystem) == 0 else { throw FileEventJournalError.filesystem(operation: "fstatfs", path: rootPath, code: errno) }
    var physicalBytes: [CChar] = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathResult: Int32 = physicalBytes.withUnsafeMutableBufferPointer { bytes in
        fcntl(descriptor, F_GETPATH_NOFIRMLINK, bytes.baseAddress!)
    }
    guard pathResult == 0 else { throw FileEventJournalError.filesystem(operation: "F_GETPATH_NOFIRMLINK", path: rootPath, code: errno) }
    let physicalPath: String? = physicalBytes.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    let mountPath: String? = withUnsafePointer(to: &filesystem.f_mntonname) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingCString: $0) }
    }
    guard let physicalPath: String, let mountPath: String else { throw FileEventJournalError.invalidPath(rootPath) }
    let relativePath: String
    if physicalPath == mountPath {
        relativePath = ""
    } else if physicalPath.hasPrefix(mountPath == "/" ? "/" : mountPath + "/") {
        relativePath = String(physicalPath.dropFirst(mountPath == "/" ? 1 : mountPath.count + 1))
    } else {
        throw FileEventJournalError.invalidPath(physicalPath)
    }
    let journalID: String? = FSEventsCopyUUIDForDevice(metadata.st_dev).map { CFUUIDCreateString(nil, $0) as String }
    return JournalIdentity(device: metadata.st_dev, relativePath: relativePath, journalID: journalID)
}

private func hostJournalIdentity() throws -> String {
    var length: Int = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0 else {
        throw FileEventJournalError.filesystem(operation: "sysctl kern.bootsessionuuid", path: "/", code: errno)
    }
    var boot: [CChar] = [CChar](repeating: 0, count: length)
    guard sysctlbyname("kern.bootsessionuuid", &boot, &length, nil, 0) == 0 else {
        throw FileEventJournalError.filesystem(operation: "sysctl kern.bootsessionuuid", path: "/", code: errno)
    }
    let bootID: String? = boot.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    guard let bootID else { throw FileEventJournalError.invalidPath("kern.bootsessionuuid") }
    let count: Int32 = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0 else { throw FileEventJournalError.filesystem(operation: "getfsstat", path: "/", code: errno) }
    let initial: statfs = statfs()
    var mounts: [statfs] = Array(repeating: initial, count: Int(count) + 16)
    let read: Int32 = mounts.withUnsafeMutableBufferPointer { buffer in
        getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    }
    guard read >= 0, read < mounts.count else { throw FileEventJournalError.filesystem(operation: "getfsstat topology", path: "/", code: errno) }
    let volumes: [String] = mounts.prefix(Int(read)).map { filesystem in
        var value: statfs = filesystem
        let device: Int32 = value.f_fsid.val.0
        let uuid: String = FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String } ?? "unavailable"
        let mount: String = withUnsafePointer(to: &value.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return "\(device):\(uuid):\(mount)"
    }
    return "host:\(bootID):" + volumes.sorted().joined(separator: "|")
}

private struct JournalBufferState: Sendable {
    var dirtyDirectories: Set<String>
    var recursiveDirectories: Set<String>
    var requiresFullScan: Bool
    var eventID: UInt64
    var historyDone: Bool
    var lastHistoryActivity: DispatchTime?
}

final class JournalEventBuffer: Sendable {
    let rootPath: String
    let relativePath: String
    let journalID: String?
    private let state: Mutex<JournalBufferState>
    private let historyFinished: DispatchSemaphore

    init(rootPath: String, relativePath: String, journalID: String?, eventID: UInt64, requiresFullScan: Bool, expectsHistory: Bool) {
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.journalID = journalID
        self.state = Mutex(JournalBufferState(dirtyDirectories: [], recursiveDirectories: [], requiresFullScan: requiresFullScan, eventID: eventID, historyDone: !expectsHistory, lastHistoryActivity: nil))
        self.historyFinished = DispatchSemaphore(value: 0)
    }

    func receive(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>, identifiers: UnsafePointer<FSEventStreamEventId>) {
        let rawPaths: UnsafeMutablePointer<UnsafePointer<CChar>> = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var events: [JournalEvent] = []
        events.reserveCapacity(count)
        var invalidPath: Bool = false
        var historyDone: Bool = false
        var latest: UInt64 = 0
        for index: Int in 0..<count {
            let eventFlags: UInt32 = flags[index]
            latest = max(latest, identifiers[index])
            if eventFlags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                continue
            }
            guard let rawPath: String = String(validatingCString: rawPaths[index]) else { invalidPath = true; continue }
            let relativeEvent: String = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
            let path: String
            if relativeEvent == relativePath {
                path = rootPath
            } else if relativePath.isEmpty || relativeEvent.hasPrefix(relativePath + "/") {
                let suffix: String = relativePath.isEmpty ? relativeEvent : String(relativeEvent.dropFirst(relativePath.count + 1))
                path = rootPath == "/" ? "/" + suffix : rootPath + "/" + suffix
            } else {
                invalidPath = true
                continue
            }
            events.append(JournalEvent(path: path, flags: eventFlags, eventID: identifiers[index]))
        }
        let scopes: JournalScopes = reconciliationScopes(events: events, rootPath: rootPath)
        let signalHistory: Bool = state.withLock { state in
            state.dirtyDirectories.formUnion(scopes.dirtyDirectories)
            state.recursiveDirectories.formUnion(scopes.recursiveDirectories)
            state.requiresFullScan = state.requiresFullScan || scopes.requiresFullScan || invalidPath
            state.eventID = max(state.eventID, latest)
            if count > 0 && !state.historyDone { state.lastHistoryActivity = .now() }
            let shouldSignal: Bool = historyDone && !state.historyDone
            state.historyDone = state.historyDone || historyDone
            return shouldSignal
        }
        if signalHistory { historyFinished.signal() }
    }

    func snapshot() -> JournalReplay {
        state.withLock { state in
            let replay: JournalReplay = JournalReplay(checkpoint: journalID.map { JournalCheckpoint(journalID: $0, eventID: state.eventID) }, dirtyDirectories: state.dirtyDirectories.sorted(), recursiveDirectories: state.recursiveDirectories.sorted(), requiresFullScan: state.requiresFullScan)
            state.dirtyDirectories.removeAll(keepingCapacity: true)
            state.recursiveDirectories.removeAll(keepingCapacity: true)
            state.requiresFullScan = false
            return replay
        }
    }

    func waitForHistory(timeout: TimeInterval, isCancelled: () -> Bool) throws {
        let started: DispatchTime = .now()
        while true {
            if isCancelled() { throw ScanError.cancelled }
            let deadline: DispatchTime? = try state.withLock { state in
                if state.historyDone { return nil }
                let activity: DispatchTime = state.lastHistoryActivity ?? started
                let deadline: DispatchTime = DispatchTime(uptimeNanoseconds: max(activity.uptimeNanoseconds, started.uptimeNanoseconds)) + timeout
                guard DispatchTime.now() < deadline else {
                    throw FileEventJournalError.replayTimedOut(path: rootPath, timeout: timeout)
                }
                return deadline
            }
            guard let deadline: DispatchTime else { return }
            _ = historyFinished.wait(timeout: min(deadline, .now() + 0.1))
        }
    }
}

public final class FileEventJournal {
    private let rootPath: String
    private let buffer: JournalEventBuffer
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    /// Commit checkpoints atomically with all indexed rows reconciled through their event ID.
    public init(rootPath: String, checkpoint: JournalCheckpoint?, latency: TimeInterval) throws {
        let normalizedRoot: String = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let identity: JournalIdentity = try journalIdentity(rootPath: normalizedRoot)
        let host: Bool = normalizedRoot == "/"
        let durableJournalID: String? = host ? try hostJournalIdentity() : identity.journalID
        let current: UInt64 = host ? FSEventsGetCurrentEventId() : FSEventsGetLastEventIdForDeviceBeforeTime(identity.device, Date().timeIntervalSince1970)
        let checkpointMatches: Bool = checkpoint != nil && checkpoint?.journalID == durableJournalID && checkpoint!.eventID < UInt64(kFSEventStreamEventIdSinceNow) && checkpoint!.eventID <= FSEventsGetCurrentEventId()
        let since: UInt64 = durableJournalID == nil ? UInt64(kFSEventStreamEventIdSinceNow) : (checkpointMatches ? checkpoint!.eventID : current)
        self.rootPath = normalizedRoot
        self.queue = DispatchQueue(label: "Disker.FileEventJournal", qos: .utility)
        self.buffer = JournalEventBuffer(rootPath: normalizedRoot, relativePath: identity.relativePath, journalID: durableJournalID, eventID: since == UInt64(kFSEventStreamEventIdSinceNow) ? 0 : since, requiresFullScan: !checkpointMatches, expectsHistory: durableJournalID != nil)
        var context: FSEventStreamContext = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(buffer).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, identifiers in
            guard let context: UnsafeMutableRawPointer else { return }
            Unmanaged<JournalEventBuffer>.fromOpaque(context).takeUnretainedValue().receive(count: count, paths: paths, flags: flags, identifiers: identifiers)
        }
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let created: FSEventStreamRef? = host
            ? FSEventStreamCreate(nil, callback, &context, ["/"] as CFArray, since, latency, flags)
            : FSEventStreamCreateRelativeToDevice(nil, callback, &context, identity.device, [identity.relativePath] as CFArray, since, latency, flags)
        guard let stream: FSEventStreamRef = created else { throw FileEventJournalError.streamCreation(normalizedRoot) }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw FileEventJournalError.streamStart(normalizedRoot)
        }
    }

    deinit { stop() }

    /// The timeout bounds inactivity while waiting for all historical events.
    public func replay(timeout: TimeInterval, isCancelled: () -> Bool) throws -> JournalReplay {
        guard stream != nil else { throw FileEventJournalError.stopped(rootPath) }
        try buffer.waitForHistory(timeout: timeout, isCancelled: isCancelled)
        return try drain()
    }

    public func drain() throws -> JournalReplay {
        guard let stream: FSEventStreamRef else { throw FileEventJournalError.stopped(rootPath) }
        FSEventStreamFlushSync(stream)
        queue.sync {}
        return buffer.snapshot()
    }

    public func stop() {
        guard let stream: FSEventStreamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
