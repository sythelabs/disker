import AppKit
import CoreFoundation
import Darwin
import DiskerCore
import Foundation

struct FileItem: Identifiable, Sendable {
    let entry: ScanEntry
    let url: URL

    var id: Data { entry.path }
    var name: String { String(decoding: entry.name, as: UTF8.self) }
    var isDirectory: Bool { entry.metadata.kind == .directory }

    init(entry: ScanEntry) throws {
        guard entry.path.first == 47, !entry.path.contains(0) else { throw FileOperationError.invalidPath(entry.path) }
        self.entry = entry
        url = try fileURL(for: entry.path)
    }
}

struct FileChange: Sendable {
    let removedURLs: [URL]
    let insertedURL: URL?
}

enum FileOperationError: Error, Equatable, LocalizedError, Sendable {
    case invalidPath(Data)
    case invalidName(String)
    case changedItem(Data)
    case systemCall(Data, Int32)
    case failed(String, URL, String)
    case missingResult(String, URL)
    case invalidDestination(URL)
    case pathNotUTF8(URL)
    case emptySelection
    case trashFailed([URL], String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Invalid file path: \(String(decoding: path, as: UTF8.self))"
        case .invalidName(let name): return "Invalid name '\(name)'. Use a nonempty name without / or null characters."
        case .changedItem(let path): return "The item changed since it was scanned: \(String(decoding: path, as: UTF8.self)). Refresh before trying again."
        case .systemCall(let path, let code): return "Could not read \(String(decoding: path, as: UTF8.self)): lstat error \(code), \(String(cString: strerror(code)))"
        case .failed(let operation, let url, let diagnostic): return "\(operation) failed for \(url.path): \(diagnostic)"
        case .missingResult(let operation, let url): return "\(operation) returned no destination for \(url.path)."
        case .invalidDestination(let url): return "Cannot copy or move an item into itself: \(url.path)"
        case .pathNotUTF8(let url): return "This path cannot be represented as text: \(url.absoluteString)"
        case .emptySelection: return "Select at least one file or folder."
        case .trashFailed(let urls, let diagnostic): return "Move to Trash failed for \(urls.map(\.path).joined(separator: ", ")): \(diagnostic)"
        }
    }
}

func trashTargets(_ items: [FileItem]) throws -> [FileItem] {
    guard !items.isEmpty else { throw FileOperationError.emptySelection }
    let directories: Set<Data> = Set(items.filter(\.isDirectory).map(\.id))
    var seen: Set<Data> = []
    return items.filter { item in
        guard seen.insert(item.id).inserted else { return false }
        var ancestor: Data = item.id
        while ancestor.count > 1, let separator: Data.Index = ancestor.lastIndex(of: 47) {
            ancestor = Data(ancestor.prefix(upTo: separator))
            if ancestor.isEmpty { ancestor = Data([47]) }
            if directories.contains(ancestor) { return false }
        }
        return true
    }
}

func filePathBytes(_ url: URL) throws -> Data {
    guard url.isFileURL else { throw FileOperationError.failed("Read path", url, "Expected a file URL") }
    guard url.host() == nil || url.host() == "" || url.host() == "localhost" else { throw FileOperationError.failed("Read path", url, "Expected a local file URL") }
    // Cocoa filesystem representations can normalize filenames; decode the URL's original bytes.
    let encoded: [UInt8] = Array(url.path(percentEncoded: true).utf8)
    var path: Data = Data()
    var offset: Int = 0
    while offset < encoded.count {
        if encoded[offset] == 37 {
            guard offset + 2 < encoded.count,
                  let byte: UInt8 = UInt8(String(decoding: encoded[(offset + 1)..<(offset + 3)], as: UTF8.self), radix: 16) else {
                throw FileOperationError.failed("Read path", url, "Invalid percent escape")
            }
            path.append(byte)
            offset += 3
        } else {
            path.append(encoded[offset])
            offset += 1
        }
    }
    while path.count > 1 && path.last == 47 { path.removeLast() }
    guard path.first == 47, !path.contains(0) else { throw FileOperationError.invalidPath(path) }
    return path
}

func fileURL(for path: Data) throws -> URL {
    guard path.first == 47, !path.contains(0) else { throw FileOperationError.invalidPath(path) }
    let native: CFURL? = path.withUnsafeBytes {
        CFURLCreateFromFileSystemRepresentation(nil, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), path.count, false)
    }
    guard let native else { throw FileOperationError.invalidPath(path) }
    return native as URL
}

private func destinationURL(source: URL, directory: URL) throws -> URL {
    let sourcePath: Data = try filePathBytes(source)
    guard let separator: Data.Index = sourcePath.lastIndex(of: 47), separator < sourcePath.index(before: sourcePath.endIndex) else {
        throw FileOperationError.invalidDestination(source)
    }
    let name: Data = sourcePath.suffix(from: sourcePath.index(after: separator))
    let directoryPath: Data = try filePathBytes(directory)
    return try fileURL(for: directoryPath + (directoryPath.last == 47 ? Data() : Data([47])) + name)
}

@MainActor final class FileOperations {
    nonisolated func lastOpenedDate(_ path: Data) async throws -> Date? {
        try await Task.detached(priority: .utility) {
            let url: URL = try fileURL(for: path)
            do { return try fileLastOpenedDate(path: path) }
            catch IndexError.invalidQuery(let diagnostic) {
                throw FileOperationError.failed("Read date last opened", url, diagnostic)
            }
        }.value
    }

    func open(_ item: FileItem) async throws {
        do { _ = try await NSWorkspace.shared.open(item.url, configuration: NSWorkspace.OpenConfiguration()) }
        catch { throw FileOperationError.failed("Open", item.url, String(describing: error)) }
    }

    func open(_ item: FileItem, with application: URL) async throws {
        do { _ = try await NSWorkspace.shared.open([item.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) }
        catch { throw FileOperationError.failed("Open with \(application.lastPathComponent)", item.url, String(describing: error)) }
    }

    func applications(for item: FileItem) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: item.url)
    }

    func reveal(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func duplicate(_ item: FileItem) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try self.validate(item) }.value
        return try await duplicateURL(item.url)
    }

    func trash(_ items: [FileItem]) async throws -> [URL: URL] {
        let targets: [FileItem] = try trashTargets(items)
        try await Task.detached(priority: .userInitiated) {
            for item: FileItem in targets { try self.validate(item) }
        }.value
        let urls: [URL] = targets.map(\.url)
        let results: [URL: URL]
        do { results = try await NSWorkspace.shared.recycle(urls) }
        catch { throw FileOperationError.trashFailed(urls, String(describing: error)) }
        for url: URL in urls {
            guard results[url] != nil else { throw FileOperationError.missingResult("Move to Trash", url) }
        }
        return results
    }

    nonisolated func rename(_ item: FileItem, to name: String) async throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw FileOperationError.invalidName(name) }
        return try await Task.detached(priority: .userInitiated) {
            try self.validate(item)
            let destination: URL = item.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: item.isDirectory)
            do { try FileManager.default.moveItem(at: item.url, to: destination) }
            catch { throw FileOperationError.failed("Rename to \(name)", item.url, String(describing: error)) }
            return destination
        }.value
    }

    func paste(_ source: URL, into directory: URL) async throws -> URL {
        if try filePathBytes(source.deletingLastPathComponent()) == filePathBytes(directory) { return try await duplicateURL(source) }
        return try await Task.detached(priority: .userInitiated) {
            let destination: URL = try destinationURL(source: source, directory: directory)
            try self.validateDestination(source: source, destination: destination)
            do { try FileManager.default.copyItem(at: source, to: destination) }
            catch { throw FileOperationError.failed("Paste into \(directory.path)", source, String(describing: error)) }
            return destination
        }.value
    }

    nonisolated func move(_ source: URL, into directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let destination: URL = try destinationURL(source: source, directory: directory)
            try self.validateDestination(source: source, destination: destination)
            do { try FileManager.default.moveItem(at: source, to: destination) }
            catch { throw FileOperationError.failed("Move into \(directory.path)", source, String(describing: error)) }
            return destination
        }.value
    }

    func copy(_ item: FileItem, to pasteboard: NSPasteboard) throws {
        try copy([item], to: pasteboard)
    }

    func copy(_ items: [FileItem], to pasteboard: NSPasteboard) throws {
        guard let first: FileItem = items.first else { throw FileOperationError.emptySelection }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items.map { $0.url as NSURL }) else { throw FileOperationError.failed("Copy", first.url, "The clipboard rejected the file URLs") }
    }

    func copyPath(_ item: FileItem, to pasteboard: NSPasteboard) throws {
        guard let path: String = String(data: item.entry.path, encoding: .utf8) else { throw FileOperationError.pathNotUTF8(item.url) }
        pasteboard.clearContents()
        guard pasteboard.setString(path, forType: .string) else { throw FileOperationError.failed("Copy Path", item.url, "The clipboard rejected the path") }
    }

    func files(on pasteboard: NSPasteboard) throws -> [URL] {
        let urls: [URL] = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return try urls.map { try fileURL(for: filePathBytes($0)) }
    }

    private func duplicateURL(_ source: URL) async throws -> URL {
        let results: [URL: URL]
        do { results = try await NSWorkspace.shared.duplicate([source]) }
        catch { throw FileOperationError.failed("Duplicate", source, String(describing: error)) }
        guard let destination: URL = results[source] else { throw FileOperationError.missingResult("Duplicate", source) }
        return destination
    }

    nonisolated private func validate(_ item: FileItem) throws {
        var live: stat = stat()
        let result: Int32 = try item.url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { throw FileOperationError.invalidPath(item.entry.path) }
            return lstat(pointer, &live)
        }
        guard result == 0 else { throw FileOperationError.systemCall(item.entry.path, errno) }
        let metadata: FileMetadata = item.entry.metadata
        guard metadata.device == UInt64(UInt32(bitPattern: live.st_dev)), metadata.inode == UInt64(live.st_ino),
              metadata.birthTime.seconds == Int64(live.st_birthtimespec.tv_sec), metadata.birthTime.nanoseconds == Int32(live.st_birthtimespec.tv_nsec) else {
            throw FileOperationError.changedItem(item.entry.path)
        }
    }

    nonisolated private func validateDestination(source: URL, destination: URL) throws {
        let sourcePath: Data = try filePathBytes(source.resolvingSymlinksInPath())
        let destinationPath: Data = try filePathBytes(destination.resolvingSymlinksInPath())
        let prefix: Data = sourcePath.last == 47 ? sourcePath : sourcePath + Data([47])
        guard destinationPath != sourcePath, !destinationPath.starts(with: prefix) else { throw FileOperationError.invalidDestination(destination) }
    }
}
