import DiskerCore
import Foundation
import Observation
import Synchronization

enum DiskTreeRowID: Hashable {
    case node(Data)
    case more(Data)
}

enum DiskTreeRow: Identifiable {
    case node(IndexedNode, depth: Int, parentBytes: UInt64)
    case more(Data, depth: Int)

    var id: DiskTreeRowID {
        switch self {
        case .node(let node, _, _): return .node(node.entry.path)
        case .more(let path, _): return .more(path)
        }
    }

    var depth: Int {
        switch self {
        case .node(_, let depth, _), .more(_, let depth): return depth
        }
    }

    var node: IndexedNode? {
        if case .node(let node, _, _) = self { return node }
        return nil
    }

    var proportion: Double? {
        guard case .node(let node, let depth, let parentBytes) = self else { return nil }
        if depth == 0 { return 1 }
        guard parentBytes > 0 else { return 0 }
        return min(1, Double(node.subtreeAllocatedBytes) / Double(parentBytes))
    }
}

func searchTreeRows(_ rows: [DiskTreeRow], query: String) -> [DiskTreeRow] {
    let text: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return rows }
    var parents: Set<Data> = []
    var matches: [DiskTreeRow] = []
    for row: DiskTreeRow in rows.reversed() {
        guard let node: IndexedNode = row.node else { continue }
        let name: String = String(decoding: node.entry.name, as: UTF8.self)
        guard parents.contains(node.entry.path) || name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
        matches.append(row)
        if let parent: Data = node.entry.parentPath { parents.insert(parent) }
    }
    return Array(matches.reversed())
}

private struct ChildPage {
    let nodes: [IndexedNode]
    let hasMore: Bool
    let parentBytes: UInt64
}

@MainActor @Observable
final class DiskTreeModel {
    private(set) var rootPath: String
    private(set) var summary: IndexSummary?
    private(set) var isScanning: Bool = false
    private(set) var isWaitingForWriter: Bool = false
    private(set) var scannedEntries: Int64 = 0
    private(set) var errorMessage: String?
    private(set) var scanStopped: Bool = false
    private(set) var expanded: Set<Data>
    private(set) var loading: Set<Data> = []
    private var rootNode: IndexedNode?
    private var pages: [Data: ChildPage] = [:]
    private var backPaths: [String] = []
    private var forwardPaths: [String] = []
    private let cacheURL: URL
    @ObservationIgnored private var index: DiskIndex?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanBuffer: TreeScanBuffer?
    private let pageSize: Int = 500

    init(rootURL: URL, cacheURL: URL) {
        let path: String = rootURL.standardizedFileURL.path
        rootPath = path
        expanded = [Data(path.utf8)]
        self.cacheURL = cacheURL
    }

    var rows: [DiskTreeRow] {
        guard let rootNode else { return [] }
        var result: [DiskTreeRow] = []
        var pending: [DiskTreeRow] = [.node(rootNode, depth: 0, parentBytes: rootNode.subtreeAllocatedBytes)]
        while let row: DiskTreeRow = pending.popLast() {
            result.append(row)
            guard let node: IndexedNode = row.node, expanded.contains(node.entry.path),
                  let page: ChildPage = pages[node.entry.path] else { continue }
            if page.hasMore { pending.append(.more(node.entry.path, depth: row.depth + 1)) }
            for child: IndexedNode in page.nodes.reversed() {
                pending.append(.node(child, depth: row.depth + 1, parentBytes: page.parentBytes))
            }
        }
        return result
    }

    var canGoBack: Bool { !backPaths.isEmpty }

    var canGoForward: Bool { !forwardPaths.isEmpty }

    func start() async {
        if index != nil { return }
        let ticket: UInt64 = generation
        let database: URL = cacheURL
        do {
            let opened: DiskIndex = try await DiskIndex.open(databaseURL: database)
            guard ticket == generation, !Task.isCancelled else { return }
            index = opened
            try await reloadSnapshot(ticket: ticket)
            guard ticket == generation, !Task.isCancelled else { return }
            refresh()
        } catch {
            if ticket == generation { errorMessage = String(describing: error) }
        }
    }

    func chooseRoot(_ url: URL) async {
        let path: String = url.standardizedFileURL.path
        guard path != rootPath else { return }
        backPaths.append(rootPath)
        forwardPaths = []
        await loadRoot(path)
    }

    func goBack() async {
        guard let path: String = backPaths.popLast() else { return }
        forwardPaths.append(rootPath)
        await loadRoot(path)
    }

    func goForward() async {
        guard let path: String = forwardPaths.popLast() else { return }
        backPaths.append(rootPath)
        await loadRoot(path)
    }

    private func loadRoot(_ path: String) async {
        cancelScan()
        generation += 1
        isScanning = false
        isWaitingForWriter = false
        scanTask = nil
        scanBuffer = nil
        rootPath = path
        expanded = [Data(rootPath.utf8)]
        pages = [:]
        loading = []
        rootNode = nil
        summary = nil
        errorMessage = nil
        scanStopped = false
        guard index != nil else { await start(); return }
        let ticket: UInt64 = generation
        do {
            try await reloadSnapshot(ticket: ticket)
            if ticket == generation { refresh() }
        } catch {
            if ticket == generation { errorMessage = String(describing: error) }
        }
    }

    func refresh() {
        beginScan(mode: .automatic)
    }

    func refreshDirectories(_ directories: [Data]) async {
        let ticket: UInt64 = generation
        cancelScan()
        await scanTask?.value
        guard ticket == generation else { return }
        beginScan(mode: .directories(directories))
        await scanTask?.value
    }

    private func beginScan(mode: RefreshMode) {
        guard let index, !isScanning else { return }
        generation += 1
        let ticket: UInt64 = generation
        let root: String = rootPath
        let buffer: TreeScanBuffer = TreeScanBuffer(root: Data(root.utf8), capturePreview: summary == nil, limit: pageSize)
        scanBuffer = buffer
        isScanning = true
        isWaitingForWriter = false
        scanStopped = false
        scannedEntries = 0
        errorMessage = nil
        scanTask = Task {
            let polling: Task<Void, Never> = Task { [weak self] in
                while !Task.isCancelled {
                    self?.applyPreview(buffer.snapshot(), ticket: ticket)
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
            defer { polling.cancel() }
            do {
                _ = try await index.refresh(root: root, mode: mode, receiveEvent: { buffer.receive($0) }, isCancelled: { buffer.isCancelled })
                guard ticket == generation else { return }
                try await reloadSnapshot(ticket: ticket)
            } catch ScanError.cancelled {
                guard ticket == generation else { return }
                scanStopped = true
                do { try await reloadSnapshot(ticket: ticket) } catch { errorMessage = String(describing: error) }
            } catch {
                guard ticket == generation else { return }
                errorMessage = String(describing: error)
                do { try await reloadSnapshot(ticket: ticket) } catch { errorMessage = String(describing: error) }
            }
            guard ticket == generation else { return }
            isScanning = false
            isWaitingForWriter = false
            scanTask = nil
            scanBuffer = nil
        }
    }

    func cancelScan() {
        scanBuffer?.cancel()
        isWaitingForWriter = false
    }

    func toggle(_ path: Data) async {
        if expanded.contains(path) { expanded.remove(path); return }
        expanded.insert(path)
        await loadPage(directory: path, offset: 0, ticket: generation)
    }

    func loadMore(_ path: Data) async {
        await loadPage(directory: path, offset: pages[path]?.nodes.count ?? 0, ticket: generation)
    }

    private func reloadSnapshot(ticket: UInt64) async throws {
        guard let index else { return }
        let root: String = rootPath
        let saved: IndexSummary? = try await index.cachedSummary(root: root)
        let node: IndexedNode? = try await index.node(root: root, path: Data(root.utf8))
        guard ticket == generation else { return }
        var reloaded: [Data: ChildPage] = [:]
        var requestedCounts: [Data: Int] = [:]
        if saved != nil {
            while let directory: Data = expanded.sorted(by: { $0.lexicographicallyPrecedes($1) }).first(where: {
                (requestedCounts[$0] ?? 0) < max(pageSize, pages[$0]?.nodes.count ?? 0)
            }) {
                let count: Int = max(pageSize, pages[directory]?.nodes.count ?? 0)
                var nodes: [IndexedNode] = []
                var page: ChildPage
                repeat {
                    page = try await queryPage(index: index, root: root, directory: directory, offset: nodes.count)
                    guard ticket == generation else { return }
                    nodes.append(contentsOf: page.nodes)
                } while page.hasMore && nodes.count < count
                reloaded[directory] = ChildPage(nodes: nodes, hasMore: page.hasMore, parentBytes: page.parentBytes)
                requestedCounts[directory] = count
            }
        }
        summary = saved
        rootNode = node
        pages = reloaded
    }

    private func loadPage(directory: Data, offset: Int, ticket: UInt64) async {
        guard let index, summary != nil, !loading.contains(directory), ticket == generation else { return }
        loading.insert(directory)
        let root: String = rootPath
        let revision: Int64? = summary?.revision
        do {
            let page: ChildPage = try await queryPage(index: index, root: root, directory: directory, offset: offset)
            let current: IndexSummary? = try await index.cachedSummary(root: root)
            guard ticket == generation, summary?.revision == revision, current?.revision == revision else {
                if ticket == generation { loading.remove(directory) }
                return
            }
            let previous: [IndexedNode] = offset == 0 ? [] : (pages[directory]?.nodes ?? [])
            pages[directory] = ChildPage(nodes: previous + page.nodes, hasMore: page.hasMore, parentBytes: page.parentBytes)
            loading.remove(directory)
        } catch {
            if ticket == generation {
                loading.remove(directory)
                errorMessage = String(describing: error)
            }
        }
    }

    private func queryPage(index: DiskIndex, root: String, directory: Data, offset: Int) async throws -> ChildPage {
        let children: [IndexedNode] = try await index.children(root: root, directory: directory, offset: offset, limit: pageSize + 1)
        let parent: IndexedNode? = try await index.node(root: root, path: directory)
        let parentBytes: UInt64
        if let target: Data = parent?.aliasTargetPath {
            parentBytes = try await index.node(root: root, path: target)?.subtreeAllocatedBytes ?? 0
        } else { parentBytes = parent?.subtreeAllocatedBytes ?? 0 }
        let projected: [IndexedNode] = children.prefix(pageSize).map { child in
            guard child.entry.parentPath != directory else { return child }
            var path: Data = directory
            if path.last != 47 { path.append(47) }
            path.append(child.entry.name)
            return IndexedNode(entry: ScanEntry(path: path, parentPath: directory, name: child.entry.name, metadata: child.entry.metadata), subtreeLogicalBytes: child.subtreeLogicalBytes, subtreeAllocatedBytes: child.subtreeAllocatedBytes, subtreeNodeCount: child.subtreeNodeCount, aliasTargetPath: child.aliasTargetPath)
        }
        return ChildPage(nodes: projected, hasMore: children.count > pageSize, parentBytes: parentBytes)
    }

    private func applyPreview(_ preview: TreeScanPreview, ticket: UInt64) {
        guard ticket == generation, isScanning else { return }
        isWaitingForWriter = preview.isWaitingForWriter && scanBuffer?.isCancelled == false
        scannedEntries = preview.progress?.entriesObserved ?? scannedEntries
        guard summary == nil, let root: ScanEntry = preview.root else { return }
        let logical: UInt64 = preview.progress?.logicalBytesObserved ?? 0
        let allocated: UInt64 = preview.progress?.allocatedBytesObserved ?? 0
        rootNode = IndexedNode(entry: root, subtreeLogicalBytes: logical, subtreeAllocatedBytes: allocated, subtreeNodeCount: max(1, scannedEntries), aliasTargetPath: nil)
        pages[root.path] = ChildPage(nodes: preview.nodes, hasMore: false, parentBytes: allocated)
    }
}

struct TreeScanPreview: Sendable {
    let root: ScanEntry?
    let nodes: [IndexedNode]
    let progress: IndexProgress?
    let isWaitingForWriter: Bool
}

private struct PreviewTotals: Sendable {
    var logical: UInt64
    var allocated: UInt64
    var count: Int64
}

private struct TreeScanState: Sendable {
    var cancelled: Bool
    var isWaitingForWriter: Bool
    var root: ScanEntry?
    var entries: [Data: ScanEntry]
    var entryOrder: [Data]
    var totals: [Data: PreviewTotals]
    var progress: IndexProgress?
}

final class TreeScanBuffer: Sendable {
    private let root: Data
    private let prefix: Data
    private let capturePreview: Bool
    private let limit: Int
    private let state: Mutex<TreeScanState>

    init(root: Data, capturePreview: Bool, limit: Int) {
        self.root = root
        prefix = root.last == 47 ? root : root + Data([47])
        self.capturePreview = capturePreview
        self.limit = limit
        state = Mutex(TreeScanState(cancelled: false, isWaitingForWriter: false, root: nil, entries: [:], entryOrder: [], totals: [:], progress: nil))
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.isWaitingForWriter = false
        }
    }

    func receive(_ event: IndexEvent) {
        state.withLock { state in
            switch event {
            case .waitingForWriter: state.isWaitingForWriter = !state.cancelled
            case .writerAcquired: state.isWaitingForWriter = false
            case .progress(let progress): state.progress = progress
            case .batch(let entries):
                guard capturePreview else { return }
                for entry: ScanEntry in entries {
                    if entry.path == root { state.root = entry; continue }
                    guard entry.path.starts(with: prefix) else { continue }
                    let suffix: Data = entry.path.dropFirst(prefix.count)
                    let component: Data = suffix.prefix { $0 != 47 }
                    let top: Data = prefix + component
                    if entry.parentPath == root, state.entries[top] != nil || state.entries.count < limit {
                        state.entries[top] = entry
                        if !state.entryOrder.contains(top) { state.entryOrder.append(top) }
                        if state.totals[top] == nil { state.totals[top] = PreviewTotals(logical: 0, allocated: 0, count: 0) }
                    }
                    guard var totals: PreviewTotals = state.totals[top] else { continue }
                    if entry.metadata.kind != .directory {
                        totals.logical += entry.metadata.logicalBytes
                        totals.allocated += entry.metadata.allocatedBytes
                    }
                    totals.count += 1
                    state.totals[top] = totals
                }
            case .started, .completed: state.isWaitingForWriter = false
            }
        }
    }

    func snapshot() -> TreeScanPreview {
        state.withLock { state in
            let nodes: [IndexedNode] = state.entryOrder.compactMap { path in
                guard let entry: ScanEntry = state.entries[path] else { return nil }
                let totals: PreviewTotals = state.totals[entry.path]!
                return IndexedNode(entry: entry, subtreeLogicalBytes: totals.logical, subtreeAllocatedBytes: totals.allocated, subtreeNodeCount: totals.count, aliasTargetPath: nil)
            }
            return TreeScanPreview(root: state.root, nodes: nodes, progress: state.progress, isWaitingForWriter: state.isWaitingForWriter)
        }
    }
}
