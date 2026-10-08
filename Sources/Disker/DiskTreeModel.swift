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
    var selection: Set<DiskTreeRowID> = []
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
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanBuffer: TreeScanBuffer?
    @ObservationIgnored private var watcherTask: Task<Void, Never>?
    @ObservationIgnored private var watcherGeneration: UInt64 = 0
    @ObservationIgnored private var pendingAutomaticRefresh: Bool = false
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

    deinit { watcherTask?.cancel() }

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
        if watcherTask != nil { return }
        let ticket: UInt64 = generation
        var watching: UInt64 = watcherGeneration
        let database: URL = cacheURL
        do {
            await scanTask?.value
            let opened: DiskIndex
            if let index { opened = index }
            else { opened = try await DiskIndex.open(databaseURL: database) }
            guard ticket == generation, watching == watcherGeneration, !Task.isCancelled else { return }
            index = opened
            try await reloadSnapshot(ticket: ticket)
            guard ticket == generation, watching == watcherGeneration, !Task.isCancelled else { return }
            watching += 1
            let attached: UInt64 = try await watchChanges(index: opened)
            guard ticket == generation, attached == watcherGeneration, !Task.isCancelled else { return }
            refresh()
        } catch {
            if ticket == generation, watching == watcherGeneration, !Task.isCancelled, !(error is CancellationError) { errorMessage = String(describing: error) }
        }
    }

    private func watchChanges(index: DiskIndex) async throws -> UInt64 {
        watcherGeneration += 1
        let ticket: UInt64 = watcherGeneration
        let root: String = rootPath
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            watcherTask = Task { [weak self] in
                let changes: AsyncThrowingStream<Void, any Error>
                do { changes = try await index.changes(root: root) }
                catch {
                    if let self, ticket == self.watcherGeneration { self.watcherTask = nil }
                    ready.resume(throwing: error)
                    return
                }
                guard !Task.isCancelled, self?.watcherGeneration == ticket else {
                    ready.resume(throwing: CancellationError())
                    return
                }
                ready.resume()
                do {
                    for try await _ in changes {
                        guard !Task.isCancelled, let self, ticket == self.watcherGeneration else { return }
                        self.requestAutomaticRefresh()
                    }
                    if !Task.isCancelled, let self, ticket == self.watcherGeneration {
                        self.watcherTask = nil
                        self.errorMessage = String(describing: FileEventJournalError.stopped(root))
                    }
                } catch {
                    if !Task.isCancelled, let self, ticket == self.watcherGeneration {
                        self.watcherTask = nil
                        self.errorMessage = String(describing: error)
                    }
                }
            }
        }
        return ticket
    }

    private func requestAutomaticRefresh() {
        guard scanBuffer?.isCancelled != true else { return }
        if isScanning { pendingAutomaticRefresh = true }
        else { beginScan(mode: .automatic) }
    }

    private func stopWatching() -> Task<Void, Never>? {
        let previous: Task<Void, Never>? = watcherTask
        watcherGeneration += 1
        watcherTask = nil
        pendingAutomaticRefresh = false
        previous?.cancel()
        return previous
    }

    func stop() {
        cancelScan()
        _ = stopWatching()
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
        let previousWatcher: Task<Void, Never>? = stopWatching()
        var watching: UInt64 = watcherGeneration
        cancelScan()
        generation += 1
        let navigation: UInt64 = generation
        let previous: Task<Void, Never>? = scanTask
        await previous?.value
        await previousWatcher?.value
        guard navigation == generation else { return }
        isScanning = false
        isWaitingForWriter = false
        scanTask = nil
        scanBuffer = nil
        guard watching == watcherGeneration, !Task.isCancelled else { return }
        selection = []
        rootPath = path
        expanded = [Data(rootPath.utf8)]
        pages = [:]
        loading = []
        rootNode = nil
        summary = nil
        errorMessage = nil
        scanStopped = false
        guard let index else { await start(); return }
        let ticket: UInt64 = generation
        do {
            try await reloadSnapshot(ticket: ticket)
            guard ticket == generation, watching == watcherGeneration, !Task.isCancelled else { return }
            watching += 1
            let attached: UInt64 = try await watchChanges(index: index)
            if ticket == generation, attached == watcherGeneration, !Task.isCancelled { refresh() }
        } catch {
            if ticket == generation, watching == watcherGeneration, !Task.isCancelled, !(error is CancellationError) { errorMessage = String(describing: error) }
        }
    }

    func refresh() {
        beginScan(mode: .automatic)
    }

    func refreshDirectories(_ directories: [Data]) async {
        let ticket: UInt64 = generation
        let watching: UInt64 = watcherGeneration
        cancelScan()
        await scanTask?.value
        guard ticket == generation, watching == watcherGeneration, !Task.isCancelled else { return }
        beginScan(mode: .directories(directories))
        while let pending: Task<Void, Never> = scanTask {
            await pending.value
            guard watching == watcherGeneration, !Task.isCancelled else { return }
        }
    }

    private func beginScan(mode: RefreshMode) {
        guard let index, !isScanning else { return }
        pendingAutomaticRefresh = false
        generation += 1
        let ticket: UInt64 = generation
        let root: String = rootPath
        let buffer: TreeScanBuffer = TreeScanBuffer()
        scanBuffer = buffer
        isScanning = true
        isWaitingForWriter = false
        scanStopped = false
        scannedEntries = summary?.nodeCount ?? 0
        errorMessage = nil
        scanTask = Task {
            let polling: Task<Void, Never> = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let sorting: UInt64 = self.sortGeneration
                    let activity: TreeScanState = buffer.snapshot()
                    guard ticket == self.generation, sorting == self.sortGeneration else { return }
                    self.isWaitingForWriter = activity.isWaitingForWriter
                    if let progress: IndexProgress = activity.progress {
                        self.scannedEntries = progress.entriesObserved
                        self.scanProgress = progress.completionFraction
                    }
                    do { try await self.reloadSnapshot(ticket: ticket) }
                    catch {
                        if Task.isCancelled { return }
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
                pendingAutomaticRefresh = false
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
            if pendingAutomaticRefresh { beginScan(mode: .automatic) }
        }
    }

    func cancelScan() {
        pendingAutomaticRefresh = false
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
        loading = []
        loadedSort = nil
        let ticket: UInt64 = generation
        let sorting: UInt64 = sortGeneration
        do { try await reloadSnapshot(ticket: ticket) }
        catch {
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
                guard try await index.cachedSummary(root: root)?.revision == saved?.revision else { return }
                if isScanning, !selection.isEmpty, loadedSort == sort, let previous: ChildPage = pages[directory] {
                    var updates: [Data: IndexedNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.entry.path, $0) })
                    for old: IndexedNode in previous.nodes where selection.contains(.node(old.entry.path)) && updates[old.entry.path] == nil {
                        updates[old.entry.path] = try await index.node(root: root, path: old.entry.path)
                    }
                    guard ticket == generation, sorting == sortGeneration else { return }
                    let paths: Set<Data> = Set(previous.nodes.map(\.entry.path))
                    nodes = previous.nodes.compactMap { updates[$0.entry.path] } + nodes.filter { !paths.contains($0.entry.path) }
                }
                reloaded[directory] = ChildPage(nodes: nodes, hasMore: page.hasMore, parentBytes: page.parentBytes)
                requestedCounts[directory] = count
            }
        }
        let progress: IndexProgress? = try await index.cachedProgress(root: root)
        guard try await index.cachedSummary(root: root)?.revision == saved?.revision else { return }
        guard ticket == generation, sorting == sortGeneration else { return }
        summary = saved
        if let progress {
            scannedEntries = progress.entriesObserved
            if !isScanning { scanProgress = progress.completionFraction }
        } else if !isScanning {
            scannedEntries = 0
            scanProgress = 0
        }
        rootNode = node
        pages = reloaded
        loadedSort = sort
    }

    private func loadPage(directory: Data, offset: Int, ticket: UInt64) async {
        guard let index, let sort: NodeSort = sortOrder.first?.sort, sort == loadedSort, !loading.contains(directory), ticket == generation else { return }
        let sorting: UInt64 = sortGeneration
        loading.insert(directory)
        let root: String = rootPath
        let revision: Int64? = summary?.revision
        do {
            let page: ChildPage = try await queryPage(index: index, root: root, directory: directory, offset: offset, sort: sort)
            let current: IndexSummary? = try await index.cachedSummary(root: root)
            guard ticket == generation, sorting == sortGeneration, summary?.revision == revision, current?.revision == revision else {
                if ticket == generation, sorting == sortGeneration { loading.remove(directory) }
                return
            }
            let previous: [IndexedNode] = offset == 0 ? [] : (pages[directory]?.nodes ?? [])
            let nodes: [IndexedNode] = previous + page.nodes
            pages[directory] = ChildPage(nodes: nodes, hasMore: page.hasMore, parentBytes: page.parentBytes)
            loading.remove(directory)
        } catch {
            if ticket == generation, sorting == sortGeneration {
                loading.remove(directory)
                errorMessage = String(describing: error)
            }
        }
    }

    private func queryPage(index: DiskIndex, root: String, directory: Data, offset: Int, sort: NodeSort) async throws -> ChildPage {
        let children: [IndexedNode] = try await index.children(root: root, directory: directory, offset: offset, limit: pageSize + 1, sort: sort)
        let parent: IndexedNode? = try await index.node(root: root, path: directory)
        let parentBytes: UInt64
        if let target: Data = parent?.aliasTargetPath {
            parentBytes = try await index.node(root: "/", path: target)?.subtreeAllocatedBytes ?? 0
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

}

struct TreeScanState: Sendable {
    var cancelled: Bool
    var isWaitingForWriter: Bool
    var progress: IndexProgress?
}

final class TreeScanBuffer: Sendable {
    private let state: Mutex<TreeScanState>

    init() {
        state = Mutex(TreeScanState(cancelled: false, isWaitingForWriter: false, progress: nil))
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
            case .writerAcquired, .started, .completed: state.isWaitingForWriter = false
            case .progress(let progress): state.progress = progress
            case .batch: break
            }
        }
    }

    func snapshot() -> TreeScanState { state.withLock { $0 } }
}
