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

struct DiskTreeSort: SortComparator {
    var sort: NodeSort

    var order: SortOrder {
        get { sort.order }
        set { sort.order = newValue }
    }

    func compare(_ lhs: DiskTreeRow, _ rhs: DiskTreeRow) -> ComparisonResult {
        switch (lhs.node, rhs.node) {
        case (.some(let left), .some(let right)): return sort.compare(left, right)
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }
}

private struct ChildPage: Sendable {
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
    private(set) var scanProgress: Double = 0
    private(set) var errorMessage: String?
    private(set) var scanStopped: Bool = false
    private(set) var expanded: Set<Data>
    private(set) var loading: Set<Data> = []
    var sortOrder: [DiskTreeSort] = [DiskTreeSort(sort: NodeSort(column: .sizeProportion, order: .reverse))]
    private var rootNode: IndexedNode?
    private var pages: [Data: ChildPage] = [:]
    private var loadedSort: NodeSort?
    private var backPaths: [String] = []
    private var forwardPaths: [String] = []
    private let cacheURL: URL
    @ObservationIgnored private let receiveScanEvent: @Sendable (IndexEvent) -> Void
    @ObservationIgnored private var index: DiskIndex?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var sortGeneration: UInt64 = 0
    @ObservationIgnored private var previewSort: NodeSort?
    @ObservationIgnored private var previewDirectoryTotals: [Data: PreviewTotals] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanBuffer: TreeScanBuffer?
    private let pageSize: Int = 500

    convenience init(rootURL: URL, cacheURL: URL) {
        self.init(rootURL: rootURL, cacheURL: cacheURL, receiveScanEvent: { _ in })
    }

    init(rootURL: URL, cacheURL: URL, receiveScanEvent: @escaping @Sendable (IndexEvent) -> Void) {
        let path: String = rootURL.standardizedFileURL.path
        rootPath = path
        expanded = [Data(path.utf8)]
        self.cacheURL = cacheURL
        self.receiveScanEvent = receiveScanEvent
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
        previewDirectoryTotals = [:]
        rootPath = path
        expanded = [Data(rootPath.utf8)]
        pages = [:]
        loading = []
        rootNode = nil
        summary = nil
        scanProgress = 0
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
        previewDirectoryTotals = [:]
        isScanning = true
        isWaitingForWriter = false
        scanStopped = false
        scannedEntries = 0
        scanProgress = 0
        errorMessage = nil
        scanTask = Task {
            let polling: Task<Void, Never> = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let sorting: UInt64 = self.sortGeneration
                    let sort: NodeSort? = self.previewSort
                    do {
                        let preview: TreeScanPreview = try await Task.detached(priority: .utility) {
                            let preview: TreeScanPreview = buffer.snapshot()
                            if let sort { return try preview.sorted(using: sort) }
                            return preview
                        }.value
                        self.applyPreview(preview, ticket: ticket, sorting: sorting)
                    } catch {
                        if ticket == self.generation, sorting == self.sortGeneration { self.errorMessage = String(describing: error) }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
            defer { polling.cancel() }
            do {
                let receiveEvent: @Sendable (IndexEvent) -> Void = receiveScanEvent
                _ = try await index.refresh(root: root, mode: mode, receiveEvent: {
                    buffer.receive($0)
                    receiveEvent($0)
                }, isCancelled: { buffer.isCancelled })
                guard ticket == generation else { return }
                try await reloadSnapshot(ticket: ticket)
                guard ticket == generation else { return }
                scanProgress = 1
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
            previewDirectoryTotals = [:]
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

    func sort() async {
        sortGeneration += 1
        previewSort = sortOrder.first?.sort
        loading = []
        let ticket: UInt64 = generation
        let sorting: UInt64 = sortGeneration
        do {
            if summary == nil {
                if let buffer: TreeScanBuffer = scanBuffer, let sort: NodeSort = previewSort {
                    let preview: TreeScanPreview = try await Task.detached(priority: .utility) {
                        try buffer.snapshot().sorted(using: sort)
                    }.value
                    applyPreview(preview, ticket: ticket, sorting: sorting)
                }
            } else { try await reloadSnapshot(ticket: ticket) }
        } catch {
            if ticket == generation, sorting == sortGeneration { errorMessage = String(describing: error) }
        }
    }

    private func reloadSnapshot(ticket: UInt64) async throws {
        guard let index, let sort: NodeSort = sortOrder.first?.sort else { return }
        let sorting: UInt64 = sortGeneration
        let root: String = rootPath
        let saved: IndexSummary? = try await index.cachedSummary(root: root)
        let node: IndexedNode? = try await index.node(root: root, path: Data(root.utf8))
        guard ticket == generation, sorting == sortGeneration, !Task.isCancelled else { return }
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
                    page = try await queryPage(index: index, root: root, directory: directory, offset: nodes.count, sort: sort)
                    guard ticket == generation, sorting == sortGeneration, !Task.isCancelled else { return }
                    nodes.append(contentsOf: page.nodes)
                } while page.hasMore && nodes.count < count
                reloaded[directory] = ChildPage(nodes: nodes, hasMore: page.hasMore, parentBytes: page.parentBytes)
                requestedCounts[directory] = count
            }
        }
        summary = saved
        rootNode = node
        pages = reloaded
        loadedSort = sort
    }

    private func loadPage(directory: Data, offset: Int, ticket: UInt64) async {
        guard let index, let sort: NodeSort = sortOrder.first?.sort, summary == nil || sort == loadedSort, !loading.contains(directory), ticket == generation else { return }
        let sorting: UInt64 = sortGeneration
        loading.insert(directory)
        let root: String = rootPath
        let revision: Int64? = summary?.revision
        do {
            let page: ChildPage
            if summary == nil {
                page = try await queryPreviewPage(directory: directory, offset: offset)
            } else {
                page = try await queryPage(index: index, root: root, directory: directory, offset: offset, sort: sort)
            }
            let current: IndexSummary? = try await index.cachedSummary(root: root)
            guard ticket == generation, sorting == sortGeneration, summary?.revision == revision, current?.revision == revision else {
                if ticket == generation, sorting == sortGeneration { loading.remove(directory) }
                return
            }
            let previous: [IndexedNode] = offset == 0 ? [] : (pages[directory]?.nodes ?? [])
            pages[directory] = ChildPage(nodes: previous + page.nodes, hasMore: page.hasMore, parentBytes: page.parentBytes)
            loading.remove(directory)
        } catch {
            if ticket == generation, sorting == sortGeneration {
                loading.remove(directory)
                errorMessage = String(describing: error)
            }
        }
    }

    private func queryPreviewPage(directory: Data, offset: Int) async throws -> ChildPage {
        let limit: Int = pageSize
        let totals: [Data: PreviewTotals] = previewDirectoryTotals
        let sort: NodeSort? = previewSort
        return try await Task.detached(priority: .utility) {
            var entries: [ScanEntry] = []
            var count: Int = 0
            var allocated: UInt64 = 0
            let options: ScanOptions = ScanOptions(batchSize: 512, bufferSize: 256 * 1024, mountPolicy: .sameDevice, excludedPaths: [])
            let summary: ScanSummary = try DirectoryScanner.enumerateDirectory(path: directory, options: options, isCancelled: { Task.isCancelled }, receiveProgress: { _ in }) { batch in
                for entry: ScanEntry in batch {
                    allocated += entry.metadata.allocatedBytes
                    guard entry.parentPath == directory else { continue }
                    if count >= offset, entries.count <= limit { entries.append(entry) }
                    count += 1
                }
            }
            if let issue: ScanIssue = summary.issues.first {
                throw IndexError.unstableFilesystem("Could not read children of \(String(decoding: directory, as: UTF8.self)): \(issue.operation), \(issue.kind.rawValue), error \(issue.errnoCode)")
            }
            var nodes: [IndexedNode] = try entries.prefix(limit).map { entry in
                let total: PreviewTotals? = totals[entry.path]
                return IndexedNode(entry: entry, subtreeLogicalBytes: total?.logical ?? (entry.metadata.kind == .directory ? 0 : entry.metadata.logicalBytes), subtreeAllocatedBytes: total?.allocated ?? entry.metadata.allocatedBytes, subtreeNodeCount: total?.count ?? 1, aliasTargetPath: nil, lastOpenedDate: sort?.column == .lastOpened ? try fileLastOpenedDate(path: entry.path) : nil)
            }
            if let sort { nodes.sort(using: sort) }
            return ChildPage(nodes: nodes, hasMore: count > offset + limit, parentBytes: max(allocated, totals[directory]?.allocated ?? 0))
        }.value
    }

    private func queryPage(index: DiskIndex, root: String, directory: Data, offset: Int, sort: NodeSort) async throws -> ChildPage {
        let children: [IndexedNode] = try await index.children(root: root, directory: directory, offset: offset, limit: pageSize + 1, sort: sort)
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
            return IndexedNode(entry: ScanEntry(path: path, parentPath: directory, name: child.entry.name, metadata: child.entry.metadata), subtreeLogicalBytes: child.subtreeLogicalBytes, subtreeAllocatedBytes: child.subtreeAllocatedBytes, subtreeNodeCount: child.subtreeNodeCount, aliasTargetPath: child.aliasTargetPath, lastOpenedDate: child.lastOpenedDate)
        }
        return ChildPage(nodes: projected, hasMore: children.count > pageSize, parentBytes: parentBytes)
    }

    private func applyPreview(_ preview: TreeScanPreview, ticket: UInt64, sorting: UInt64) {
        guard ticket == generation, sorting == sortGeneration, isScanning else { return }
        isWaitingForWriter = preview.isWaitingForWriter && scanBuffer?.isCancelled == false
        scannedEntries = preview.progress?.entriesObserved ?? scannedEntries
        scanProgress = preview.progress?.completionFraction ?? scanProgress
        guard summary == nil, let root: ScanEntry = preview.root else { return }
        previewDirectoryTotals = preview.directoryTotals
        rootNode = IndexedNode(entry: root, subtreeLogicalBytes: preview.totals.logical, subtreeAllocatedBytes: preview.totals.allocated, subtreeNodeCount: preview.totals.count, aliasTargetPath: nil)
        let rootNodes: [IndexedNode]
        if let previous: ChildPage = pages[root.path], previous.nodes.count > preview.nodes.count {
            rootNodes = previous.nodes.map { preview.updating($0) }
        } else { rootNodes = preview.nodes }
        pages[root.path] = ChildPage(nodes: rootNodes, hasMore: preview.rootChildCount > rootNodes.count, parentBytes: preview.totals.allocated)
        for (path, page): (Data, ChildPage) in pages where path != root.path {
            pages[path] = ChildPage(nodes: page.nodes.map { preview.updating($0) }, hasMore: page.hasMore, parentBytes: max(page.parentBytes, preview.directoryTotals[path]?.allocated ?? 0))
        }
    }
}

struct TreeScanPreview: Sendable {
    let root: ScanEntry?
    let nodes: [IndexedNode]
    let progress: IndexProgress?
    let isWaitingForWriter: Bool
    let totals: PreviewTotals
    let directoryTotals: [Data: PreviewTotals]
    let rootChildCount: Int

    func updating(_ node: IndexedNode) -> IndexedNode {
        guard let total: PreviewTotals = directoryTotals[node.entry.path] else { return node }
        return IndexedNode(entry: node.entry, subtreeLogicalBytes: total.logical, subtreeAllocatedBytes: total.allocated, subtreeNodeCount: total.count, aliasTargetPath: node.aliasTargetPath, lastOpenedDate: node.lastOpenedDate)
    }

    func sorted(using sort: NodeSort) throws -> TreeScanPreview {
        let enriched: [IndexedNode]
        if sort.column == .lastOpened {
            enriched = try nodes.map { node in
                IndexedNode(entry: node.entry, subtreeLogicalBytes: node.subtreeLogicalBytes, subtreeAllocatedBytes: node.subtreeAllocatedBytes, subtreeNodeCount: node.subtreeNodeCount, aliasTargetPath: node.aliasTargetPath, lastOpenedDate: try fileLastOpenedDate(path: node.entry.path))
            }
        } else { enriched = nodes }
        return TreeScanPreview(root: root, nodes: enriched.sorted(using: sort), progress: progress, isWaitingForWriter: isWaitingForWriter, totals: totals, directoryTotals: directoryTotals, rootChildCount: rootChildCount)
    }
}

struct PreviewTotals: Sendable {
    var logical: UInt64
    var allocated: UInt64
    var count: Int64
}

private struct DirectoryPreview: Sendable {
    let ownAllocated: UInt64
    var files: PreviewTotals
    var children: Set<Data>
}

private struct TreeScanState: Sendable {
    var cancelled: Bool
    var isWaitingForWriter: Bool
    var root: ScanEntry?
    var entries: [Data: ScanEntry]
    var entryOrder: [Data]
    var directories: [Data: DirectoryPreview]
    var lastDirectory: Data?
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
        state = Mutex(TreeScanState(cancelled: false, isWaitingForWriter: false, root: nil, entries: [:], entryOrder: [], directories: [:], lastDirectory: nil, progress: nil))
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
                    if entry.parentPath == nil {
                        if entry.path == root {
                            state.root = entry
                            state.entries.removeAll(keepingCapacity: true)
                        }
                        state.lastDirectory = nil
                        state.directories[entry.path] = DirectoryPreview(ownAllocated: entry.metadata.allocatedBytes, files: PreviewTotals(logical: 0, allocated: 0, count: 0), children: [])
                        continue
                    }
                    guard entry.path.starts(with: prefix) else { continue }
                    guard let parent: Data = entry.parentPath else { continue }
                    if state.lastDirectory != parent {
                        let own: UInt64 = state.directories[parent]?.ownAllocated ?? 0
                        state.directories[parent] = DirectoryPreview(ownAllocated: own, files: PreviewTotals(logical: 0, allocated: 0, count: 0), children: [])
                        state.lastDirectory = parent
                        if parent == root { state.entries.removeAll(keepingCapacity: true) }
                    }
                    if parent == root, state.entries[entry.path] != nil || state.entries.count < limit {
                        state.entries[entry.path] = entry
                        if !state.entryOrder.contains(entry.path) { state.entryOrder.append(entry.path) }
                    }
                    var directory: DirectoryPreview = state.directories[parent]!
                    if entry.metadata.kind == .directory {
                        directory.children.insert(entry.path)
                        let previous: DirectoryPreview? = state.directories[entry.path]
                        state.directories[entry.path] = DirectoryPreview(ownAllocated: entry.metadata.allocatedBytes, files: previous?.files ?? PreviewTotals(logical: 0, allocated: 0, count: 0), children: previous?.children ?? [])
                    } else {
                        directory.files.logical += entry.metadata.logicalBytes
                        directory.files.allocated += entry.metadata.allocatedBytes
                        directory.files.count += 1
                    }
                    state.directories[parent] = directory
                }
            case .started, .completed: state.isWaitingForWriter = false
            }
        }
    }

    func snapshot() -> TreeScanPreview {
        state.withLock { state in
            var totals: [Data: PreviewTotals] = [:]
            var pending: [(path: Data, visited: Bool)] = [(root, false)]
            while let item: (path: Data, visited: Bool) = pending.popLast() {
                guard let directory: DirectoryPreview = state.directories[item.path] else { continue }
                if !item.visited {
                    pending.append((item.path, true))
                    for child: Data in directory.children { pending.append((child, false)) }
                    continue
                }
                var total: PreviewTotals = PreviewTotals(logical: directory.files.logical, allocated: directory.ownAllocated + directory.files.allocated, count: 1 + directory.files.count)
                for child: Data in directory.children {
                    guard let subtotal: PreviewTotals = totals[child] else { continue }
                    total.logical += subtotal.logical
                    total.allocated += subtotal.allocated
                    total.count += subtotal.count
                }
                totals[item.path] = total
            }
            let nodes: [IndexedNode] = state.entryOrder.compactMap { path in
                guard let entry: ScanEntry = state.entries[path] else { return nil }
                let total: PreviewTotals = totals[entry.path] ?? PreviewTotals(logical: entry.metadata.logicalBytes, allocated: entry.metadata.allocatedBytes, count: 1)
                return IndexedNode(entry: entry, subtreeLogicalBytes: total.logical, subtreeAllocatedBytes: total.allocated, subtreeNodeCount: total.count, aliasTargetPath: nil)
            }
            let rootDirectory: DirectoryPreview? = state.directories[root]
            let childCount: Int = Int(rootDirectory?.files.count ?? 0) + (rootDirectory?.children.count ?? 0)
            return TreeScanPreview(root: state.root, nodes: nodes, progress: state.progress, isWaitingForWriter: state.isWaitingForWriter, totals: totals[root] ?? PreviewTotals(logical: 0, allocated: 0, count: 0), directoryTotals: totals, rootChildCount: childCount)
        }
    }
}
