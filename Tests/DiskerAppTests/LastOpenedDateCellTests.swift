import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Disker

private enum DateCellTestError: Error, LocalizedError {
    case readFailed
    case missingRequest(Int)
    case timedOut(String)
    case cleanup

    var errorDescription: String? {
        switch self {
        case .readFailed: return "Date lookup failed"
        case .missingRequest(let index): return "No pending date request at index \(index)"
        case .timedOut(let operation): return "Timed out \(operation)"
        case .cleanup: return "Date cell test ended"
        }
    }
}

enum DateCellOutcome: CaseIterable {
    case unchanged
    case changed
    case unavailable
    case failure

    fileprivate var result: Result<Date?, DateCellTestError> {
        switch self {
        case .unchanged: return .success(Date(timeIntervalSince1970: 1_000_000))
        case .changed: return .success(Date(timeIntervalSince1970: 2_000_000))
        case .unavailable: return .success(nil)
        case .failure: return .failure(.readFailed)
        }
    }
}

@MainActor private final class DateCellReader {
    private(set) var paths: [Data] = []
    private(set) var finished: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Date?, any Error>] = [:]

    func read(_ path: Data) async throws -> Date? {
        let index: Int = paths.count
        paths.append(path)
        defer { finished.insert(index) }
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
        }
    }

    func finish(_ index: Int, result: Result<Date?, DateCellTestError>) throws {
        guard let continuation: CheckedContinuation<Date?, any Error> = pending.removeValue(forKey: index) else {
            throw DateCellTestError.missingRequest(index)
        }
        continuation.resume(with: result)
    }

    func finishPending() {
        let continuations: [CheckedContinuation<Date?, any Error>] = Array(pending.values)
        pending = [:]
        for continuation: CheckedContinuation<Date?, any Error> in continuations {
            continuation.resume(throwing: DateCellTestError.cleanup)
        }
    }
}

@MainActor private struct DateCellHost {
    let view: NSHostingView<LastOpenedDateCell>
    let window: NSWindow

    init(path: Data, revision: Int64?, reader: DateCellReader) {
        _ = NSApplication.shared
        let frame: NSRect = NSRect(x: 0, y: 0, width: 360, height: 80)
        view = NSHostingView(rootView: LastOpenedDateCell(path: path, revision: revision, read: reader.read))
        view.sizingOptions = []
        view.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
    }

    func update(path: Data, revision: Int64?, reader: DateCellReader) {
        view.rootView = LastOpenedDateCell(path: path, revision: revision, read: reader.read)
        view.layoutSubtreeIfNeeded()
    }

    func pixels() throws -> Data {
        view.layoutSubtreeIfNeeded()
        let image: NSBitmapImageRep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let bytes: UnsafeMutablePointer<UInt8> = try #require(image.bitmapData)
        let count: Int = image.bytesPerRow * image.pixelsHigh
        bytes.initialize(repeating: 0, count: count)
        view.cacheDisplay(in: view.bounds, to: image)
        return Data(bytes: bytes, count: count)
    }
}

@MainActor private func waitForDateCell(_ operation: String, until predicate: () throws -> Bool) async throws {
    let deadline: Date = Date().addingTimeInterval(5)
    while try !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard try predicate() else { throw DateCellTestError.timedOut(operation) }
}

@Suite("Date last opened cell", .serialized)
@MainActor struct LastOpenedDateCellTests {
    @Test(arguments: DateCellOutcome.allCases)
    func revisionRetainsTheRenderedDateUntilTheReadCompletes(outcome: DateCellOutcome) async throws {
        let path: Data = Data("/date-cell/file".utf8)
        let reader: DateCellReader = DateCellReader()
        let host: DateCellHost = DateCellHost(path: path, revision: 1, reader: reader)
        defer { host.window.close(); reader.finishPending() }
        let original: Date = Date(timeIntervalSince1970: 1_000_000)
        try await waitForDateCell("starting the initial read", until: { reader.paths.count == 1 })
        let placeholder: Data = try host.pixels()
        try reader.finish(0, result: .success(original))
        try await waitForDateCell("rendering the original date", until: { try host.pixels() != placeholder })
        let originalPixels: Data = try host.pixels()

        host.update(path: path, revision: 2, reader: reader)
        try await waitForDateCell("starting the revision read", until: { reader.paths.count == 2 })
        #expect(try host.pixels() == originalPixels, "A summary revision replaced the visible date with a loading placeholder")
        try reader.finish(1, result: outcome.result)
        try await waitForDateCell("completing the revision read", until: { reader.finished.contains(1) })
        switch outcome {
        case .unchanged:
            try await waitForDateCell("rendering the unchanged date", until: { try host.pixels() == originalPixels })
        case .changed:
            try await waitForDateCell("rendering the changed date", until: { try host.pixels() != originalPixels && host.pixels() != placeholder })
        case .unavailable, .failure:
            try await waitForDateCell("rendering the unavailable date", until: { try host.pixels() == placeholder })
        }
        #expect(reader.paths == [path, path])
    }

    @Test func unchangedRevisionDoesNotStartAnotherRead() async throws {
        let path: Data = Data("/date-cell/file".utf8)
        let reader: DateCellReader = DateCellReader()
        let host: DateCellHost = DateCellHost(path: path, revision: 1, reader: reader)
        defer { host.window.close(); reader.finishPending() }
        try await waitForDateCell("starting the read", until: { reader.paths.count == 1 })
        let placeholder: Data = try host.pixels()
        try reader.finish(0, result: .success(nil))
        try await waitForDateCell("completing the read", until: { reader.finished.contains(0) })
        host.update(path: path, revision: 1, reader: reader)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.paths == [path])
        #expect(try host.pixels() == placeholder)
    }

    @Test func failedDateReadRecoversOnTheNextRevision() async throws {
        let path: Data = Data("/date-cell/file".utf8)
        let reader: DateCellReader = DateCellReader()
        let host: DateCellHost = DateCellHost(path: path, revision: 1, reader: reader)
        defer { host.window.close(); reader.finishPending() }
        try await waitForDateCell("starting the initial read", until: { reader.paths.count == 1 })
        let placeholder: Data = try host.pixels()
        try reader.finish(0, result: .failure(.readFailed))
        try await waitForDateCell("completing the failed read", until: { reader.finished.contains(0) })
        host.update(path: path, revision: 2, reader: reader)
        try await waitForDateCell("starting the recovery read", until: { reader.paths.count == 2 })
        #expect(try host.pixels() == placeholder)
        let recovered: Date = Date(timeIntervalSince1970: 2_000_000)
        try reader.finish(1, result: .success(recovered))
        try await waitForDateCell("rendering the recovered date", until: { try host.pixels() != placeholder })
    }

    @Test(arguments: [DateCellOutcome.unchanged, .failure])
    func cancelledOlderReadsCannotReplaceTheNewerDate(outcome: DateCellOutcome) async throws {
        let path: Data = Data("/date-cell/file".utf8)
        let reader: DateCellReader = DateCellReader()
        let host: DateCellHost = DateCellHost(path: path, revision: 1, reader: reader)
        defer { host.window.close(); reader.finishPending() }
        try await waitForDateCell("starting the older read", until: { reader.paths.count == 1 })
        let placeholder: Data = try host.pixels()
        host.update(path: path, revision: 2, reader: reader)
        try await waitForDateCell("starting the newer read", until: { reader.paths.count == 2 })
        let newest: Date = Date(timeIntervalSince1970: 2_000_000)
        try reader.finish(1, result: .success(newest))
        try await waitForDateCell("rendering the newer date", until: { try host.pixels() != placeholder })
        let newestPixels: Data = try host.pixels()
        try reader.finish(0, result: outcome.result)
        try await waitForDateCell("finishing the cancelled read", until: { reader.finished.contains(0) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(try host.pixels() == newestPixels)
    }

    @Test func changedPathNeverDisplaysThePreviousPathsDate() async throws {
        let first: Data = Data("/date-cell/first".utf8)
        let second: Data = Data("/date-cell/second".utf8)
        let reader: DateCellReader = DateCellReader()
        let host: DateCellHost = DateCellHost(path: first, revision: 1, reader: reader)
        defer { host.window.close(); reader.finishPending() }
        let old: Date = Date(timeIntervalSince1970: 1_000_000)
        try await waitForDateCell("starting the first path read", until: { reader.paths.count == 1 })
        let placeholder: Data = try host.pixels()
        try reader.finish(0, result: .success(old))
        try await waitForDateCell("rendering the first path date", until: { try host.pixels() != placeholder })
        host.update(path: second, revision: 1, reader: reader)
        try await waitForDateCell("starting the second path read", until: { reader.paths.count == 2 })
        #expect(try host.pixels() == placeholder)
        try reader.finish(1, result: .success(nil))
        try await waitForDateCell("completing the second path read", until: { reader.finished.contains(1) })
        #expect(reader.paths == [first, second])
    }
}
