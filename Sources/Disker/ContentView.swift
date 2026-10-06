import AppKit
import Combine
import DiskerCore
import Foundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model: DiskTreeModel
    @State private var locations: SidebarLocations
    @State private var sidebarSelection: SidebarSelection?
    @State private var selection: Set<DiskTreeRowID> = []
    @State private var searchText: String = ""
    @State private var choosingFolder: Bool = false
    @State private var showingIssues: Bool = false
    @State private var folderPickerError: String?
    @State private var fileOperationError: String?
    @State private var previewURL: URL?
    @State private var renaming: FileItem?
    @State private var choosingApplication: Bool = false
    @State private var applicationItem: FileItem?
    @State private var operating: Bool = false
    @State private var clipboardItems: [URL] = []
    private let operations: FileOperations = FileOperations()

    init(rootURL: URL, cacheURL: URL) {
        _model = State(initialValue: DiskTreeModel(rootURL: rootURL, cacheURL: cacheURL))
        _locations = State(initialValue: SidebarLocations(homeURL: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard))
    }

    var body: some View {
        NavigationSplitView {
            LocationSidebar(locations: locations, selection: sidebarSelectionBinding)
            .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                tree
                Divider()
                TreeScanStatus(model: model, issues: blockingIssues, showingIssues: $showingIssues)
            }
            .navigationTitle(rootTitle)
            .navigationSubtitle(model.rootPath)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search expanded folders")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") {
                        Task { await model.goBack() }
                    }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Go to the previous folder")
                    Button("Forward", systemImage: "chevron.right") {
                        Task { await model.goForward() }
                    }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Go to the next folder")
                }
                ToolbarItemGroup {
                    Button("Choose Folder", systemImage: "folder") { choosingFolder = true }
                        .help("Choose the root of the file tree")
                        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                            switch result {
                            case .success(let url): chooseRoot(url)
                            case .failure(let error): folderPickerError = error.localizedDescription
                            }
                        }
                    if model.isScanning {
                        Button("Stop Scan", systemImage: "stop.fill") { model.cancelScan() }
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                            .keyboardShortcut("r", modifiers: .command)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 940, minHeight: 440)
        .alert("Could not choose folder", isPresented: Binding(get: { folderPickerError != nil }, set: { if !$0 { folderPickerError = nil } })) {
            Button("OK", role: .cancel) { folderPickerError = nil }
        } message: { Text(folderPickerError ?? "") }
        .fileImporter(isPresented: $choosingApplication, allowedContentTypes: [.applicationBundle]) { result in
            switch result {
            case .success(let application):
                if let item: FileItem = applicationItem {
                    Task {
                        do { try await operations.open(item, with: application) }
                        catch { fileOperationError = error.localizedDescription }
                    }
                }
            case .failure(let error): fileOperationError = error.localizedDescription
            }
        }
        .alert("File operation failed", isPresented: Binding(get: { fileOperationError != nil }, set: { if !$0 { fileOperationError = nil } })) {
            Button("OK", role: .cancel) { fileOperationError = nil }
        } message: { Text(fileOperationError ?? "") }
        .quickLookPreview($previewURL)
        .sheet(item: $renaming) { item in
            RenameItemSheet(item: item) { name in
                renaming = nil
                rename(item, to: name)
            }
        }
        .alert("Some locations could not be read", isPresented: $showingIssues) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockingIssues.prefix(20).map { "\(String(decoding: $0.path, as: UTF8.self)): \($0.operation), error \($0.errnoCode)" }.joined(separator: "\n"))
        }
        .task {
            do { clipboardItems = try operations.files(on: .general) }
            catch { fileOperationError = error.localizedDescription }
            await model.start()
        }
        .task { await locations.load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification))) { _ in
            Task { await locations.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            do { clipboardItems = try operations.files(on: .general) }
            catch { fileOperationError = error.localizedDescription }
        }
        .onDisappear { model.cancelScan() }
        .onChange(of: model.rootPath) { _, _ in
            selection = []
            searchText = ""
        }
        .onChange(of: searchText) { _, _ in selection = [] }
        .onChange(of: model.sortOrder) { _, _ in
            Task { await model.sort() }
        }
    }

    private var tree: some View {
        Table(of: DiskTreeRow.self, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", sortUsing: DiskTreeSort(sort: NodeSort(column: .name, order: .forward))) { row in
                TreeNameCell(row: row, model: model)
            }
            .width(min: nameColumnMinimum, ideal: max(440, nameColumnMinimum), max: .infinity)
            TableColumn("Proportion", sortUsing: DiskTreeSort(sort: NodeSort(column: .sizeProportion, order: .reverse))) { row in
                if let proportion: Double = row.proportion {
                    SizeProportionBar(proportion: proportion)
                }
            }
            .width(min: 150, ideal: 180, max: 300)
            TableColumn("Allocated size", sortUsing: DiskTreeSort(sort: NodeSort(column: .allocatedSize, order: .reverse))) { row in
                if let node: IndexedNode = row.node { Text(fileSize(node.subtreeAllocatedBytes)).monospacedDigit() }
            }
            .width(min: 120, ideal: 130, max: 180)
            .alignment(.trailing)
            TableColumn("Date Last Opened", sortUsing: DiskTreeSort(sort: NodeSort(column: .lastOpened, order: .reverse))) { row in
                if let node: IndexedNode = row.node {
                    if model.sortOrder.first?.sort.column == .lastOpened, row.depth > 0 {
                        Text(lastOpenedLabel(node.lastOpenedDate))
                            .lineLimit(1)
                            .help(node.lastOpenedDate == nil ? "Date last opened unavailable" : lastOpenedLabel(node.lastOpenedDate))
                    } else {
                        LastOpenedDateCell(path: node.entry.path, operations: operations)
                            .id(model.summary?.revision)
                    }
                }
            }
            .width(min: 190, ideal: 230, max: 320)
            TableColumn("Items", sortUsing: DiskTreeSort(sort: NodeSort(column: .items, order: .reverse))) { row in
                if let node: IndexedNode = row.node {
                    Text(node.itemCount.formatted())
                        .monospacedDigit()
                }
            }
            .width(min: 75, ideal: 90, max: 140)
            .alignment(.trailing)
        } rows: {
            ForEach(visibleRows) { row in
                TableRow(row)
                    .itemProvider {
                        guard let node: IndexedNode = row.node, node.entry.metadata.kind == .directory else { return nil }
                        do { return NSItemProvider(object: try FileItem(entry: node.entry).url as NSURL) }
                        catch { fileOperationError = error.localizedDescription; return nil }
                    }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: DiskTreeRowID.self) { ids in
            if ids.count == 1, case .more(let path) = ids.first {
                Button("Load more items") { Task { await model.loadMore(path) } }
            } else if let node: IndexedNode = node(in: ids) {
                switch Result(catching: { try FileItem(entry: node.entry) }) {
                case .success(let item): fileMenu(item)
                case .failure(let error): Button("Could not access item") { fileOperationError = error.localizedDescription }
                }
            } else if ids.isEmpty {
                pasteMenu(into: URL(fileURLWithPath: model.rootPath))
            } else {
                Button("Copy Selected Items") { copySelection(ids) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Reveal in Finder") {
                    do { NSWorkspace.shared.activateFileViewerSelecting(try selectedItems(ids).map(\.url)) }
                    catch { fileOperationError = error.localizedDescription }
                }
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) { trashSelection(ids) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(operating)
            }
        } primaryAction: { ids in
            if ids.count == 1, case .more(let path) = ids.first { Task { await model.loadMore(path) } }
            else if let node: IndexedNode = node(in: ids) {
                do { open(try FileItem(entry: node.entry)) }
                catch { fileOperationError = error.localizedDescription }
            }
        }
        .onKeyPress(.rightArrow) {
            guard selection.count == 1, case .node(let path) = selection.first,
                  let row: DiskTreeRow = model.rows.first(where: { selection.contains($0.id) }),
                  row.node?.entry.metadata.kind == .directory else { return .ignored }
            if model.expanded.contains(path) {
                if let child: DiskTreeRow = visibleRows.first(where: { $0.node?.entry.parentPath == path }) { selection = [child.id] }
            } else { Task { await model.toggle(path) } }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard selection.count == 1, case .node(let path) = selection.first,
                  let row: DiskTreeRow = model.rows.first(where: { selection.contains($0.id) }) else { return .ignored }
            if model.expanded.contains(path) { Task { await model.toggle(path) } }
            else if let parent: Data = row.node?.entry.parentPath { selection = [.node(parent)] }
            else { return .ignored }
            return .handled
        }
        .onKeyPress(phases: .down, action: handleFileKeyPress)
        .overlay {
            if visibleRows.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No matching files or folders", systemImage: "magnifyingglass", description: Text("Try a different search in the expanded folders."))
                } else if model.isScanning {
                    VStack(spacing: 12) { ProgressView(); Text("Reading file tree").foregroundStyle(.secondary) }
                } else {
                    ContentUnavailableView(model.scanStopped ? "Scan stopped" : "No indexed files", systemImage: "folder", description: Text("Choose a folder or refresh to read its file tree."))
                }
            }
        }
    }

    private var visibleRows: [DiskTreeRow] { searchTreeRows(model.rows, query: searchText) }

    private var blockingIssues: [ScanIssue] {
        model.summary?.issues.filter { ![.excluded, .directoryAlias, .mountBoundary].contains($0.kind) } ?? []
    }

    private var nameColumnMinimum: CGFloat { CGFloat((model.rows.map(\.depth).max() ?? 0) * 16 + 300) }

    private var rootURL: URL { URL(fileURLWithPath: model.rootPath) }

    private var rootTitle: String { model.rootPath == "/" ? "File System" : rootURL.lastPathComponent }

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: {
                let destinations: [SidebarSelection] = locations.favorites.map { SidebarSelection(section: .favorites, path: $0.id) }
                    + locations.local.map { SidebarSelection(section: .local, path: $0.id) }
                    + locations.network.map { SidebarSelection(section: .network, path: $0.id) }
                if let sidebarSelection, sidebarSelection.path == model.rootPath, destinations.contains(sidebarSelection) { return sidebarSelection }
                return destinations.first { $0.path == model.rootPath }
            },
            set: { destination in
                sidebarSelection = destination
                if let destination, destination.path != model.rootPath { chooseRoot(URL(fileURLWithPath: destination.path)) }
            }
        )
    }

    private func chooseRoot(_ url: URL) {
        selection = []
        Task { await model.chooseRoot(url) }
    }

    private func node(in ids: Set<DiskTreeRowID>) -> IndexedNode? {
        guard ids.count == 1, let id: DiskTreeRowID = ids.first else { return nil }
        return model.rows.first { $0.id == id }?.node
    }

    @ViewBuilder private func fileMenu(_ item: FileItem) -> some View {
        Button("Open", systemImage: "arrow.up.forward.app") { open(item) }
            .keyboardShortcut("o", modifiers: .command)
        if !item.isDirectory {
            Menu("Open With") {
                ForEach(operations.applications(for: item), id: \.self) { application in
                    Button(FileManager.default.displayName(atPath: application.path)) {
                        Task {
                            do { try await operations.open(item, with: application) }
                            catch { fileOperationError = error.localizedDescription }
                        }
                    }
                }
                Divider()
                Button("Other Application") { applicationItem = item; choosingApplication = true }
            }
        } else {
            Button(model.expanded.contains(item.id) ? "Collapse Folder" : "Expand Folder") { Task { await model.toggle(item.id) } }
        }
        Button("Quick Look", systemImage: "eye") { previewURL = item.url }
            .keyboardShortcut(.space, modifiers: [])
        Button("Reveal in Finder", systemImage: "folder") { operations.reveal(item) }
        Divider()
        Button("Rename") { renaming = item }.disabled(operating)
        Button("Duplicate") { duplicate(item) }.keyboardShortcut("d", modifiers: .command).disabled(operating)
        Button("Copy") { copy(item) }.keyboardShortcut("c", modifiers: .command)
        Button("Copy Path") { copyPath(item) }.keyboardShortcut("c", modifiers: [.command, .option])
        pasteMenu(into: item.isDirectory ? item.url : item.url.deletingLastPathComponent())
        ShareLink("Share", item: item.url)
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { trashSelection([.node(item.id)]) }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(operating)
    }

    @ViewBuilder private func pasteMenu(into directory: URL) -> some View {
        Button("Paste Item") { paste(into: directory) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(operating || clipboardItems.isEmpty)
        Button("Move Item Here") { move(into: directory) }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(operating || clipboardItems.isEmpty)
    }

    private func open(_ item: FileItem) {
        Task {
            do {
                if item.isDirectory {
                    guard String(data: item.id, encoding: .utf8) != nil else { throw FileOperationError.pathNotUTF8(item.url) }
                    selection = []
                    await model.chooseRoot(item.url)
                } else { try await operations.open(item) }
            } catch { fileOperationError = error.localizedDescription }
        }
    }

    private func selectedItems(_ ids: Set<DiskTreeRowID>) throws -> [FileItem] {
        try visibleRows.filter { ids.contains($0.id) }.compactMap { row in
            guard let node: IndexedNode = row.node else { return nil }
            return try FileItem(entry: node.entry)
        }
    }

    private func copySelection(_ ids: Set<DiskTreeRowID>) {
        do {
            try operations.copy(try selectedItems(ids), to: .general)
            clipboardItems = try operations.files(on: .general)
        } catch { fileOperationError = error.localizedDescription }
    }

    private func copy(_ item: FileItem) {
        do {
            try operations.copy(item, to: .general)
            clipboardItems = try operations.files(on: .general)
        } catch { fileOperationError = error.localizedDescription }
    }

    private func copyPath(_ item: FileItem) {
        do {
            try operations.copyPath(item, to: .general)
            clipboardItems = try operations.files(on: .general)
        } catch { fileOperationError = error.localizedDescription }
    }

    private func rename(_ item: FileItem, to name: String) {
        performMutation(in: [item.url.deletingLastPathComponent()]) {
            let destination: URL = try await operations.rename(item, to: name)
            return FileChange(removedURLs: [item.url], insertedURL: destination)
        }
    }

    private func duplicate(_ item: FileItem) {
        performMutation(in: [item.url.deletingLastPathComponent()]) {
            let destination: URL = try await operations.duplicate(item)
            return FileChange(removedURLs: [], insertedURL: destination)
        }
    }

    private func trashSelection(_ ids: Set<DiskTreeRowID>) {
        do {
            let items: [FileItem] = try trashTargets(selectedItems(ids))
            performMutation(in: Array(Set(items.map { $0.url.deletingLastPathComponent() }))) {
                let results: [URL: URL] = try await operations.trash(items)
                return FileChange(removedURLs: Array(results.keys), insertedURL: nil)
            }
        } catch { fileOperationError = error.localizedDescription }
    }

    private func paste(into directory: URL) {
        let sources: [URL]
        do { sources = try operations.files(on: .general) }
        catch { fileOperationError = error.localizedDescription; return }
        performMutation(in: [directory]) {
            var destination: URL?
            guard !sources.isEmpty else { throw FileOperationError.failed("Paste", directory, "No files on the clipboard") }
            for source: URL in sources { destination = try await operations.paste(source, into: directory) }
            return FileChange(removedURLs: [], insertedURL: destination)
        }
    }

    private func move(into directory: URL) {
        let sources: [URL]
        do { sources = try operations.files(on: .general) }
        catch { fileOperationError = error.localizedDescription; return }
        performMutation(in: sources.map { $0.deletingLastPathComponent() } + [directory]) {
            var destination: URL?
            guard !sources.isEmpty else { throw FileOperationError.failed("Move", directory, "No files on the clipboard") }
            for source: URL in sources { destination = try await operations.move(source, into: directory) }
            return FileChange(removedURLs: sources, insertedURL: destination)
        }
    }

    private func performMutation(in directories: [URL], operation: @escaping @MainActor () async throws -> FileChange) {
        guard !operating else { return }
        operating = true
        let originalRoot: String = model.rootPath
        let originalSelection: Set<DiskTreeRowID> = selection
        Task {
            defer { operating = false }
            var change: FileChange?
            do { change = try await operation() }
            catch { fileOperationError = error.localizedDescription }
            guard model.rootPath == originalRoot else { return }
            do {
                let root: Data = Data(model.rootPath.utf8)
                if let removed: URL = try change?.removedURLs.first(where: { try filePathBytes($0) == root }) {
                    selection = []
                    await model.chooseRoot(change?.insertedURL ?? removed.deletingLastPathComponent())
                } else {
                    let prefix: Data = root.last == 47 ? root : root + Data([47])
                    let paths: [Data] = try directories.map(filePathBytes).filter { $0 == root || $0.starts(with: prefix) }
                    if !paths.isEmpty { await model.refreshDirectories(paths) }
                    guard model.rootPath == originalRoot else { return }
                    if selection == originalSelection {
                        if let inserted: URL = change?.insertedURL {
                            let id: DiskTreeRowID = .node(try filePathBytes(inserted))
                            if model.rows.contains(where: { $0.id == id }) { selection = [id] }
                        }
                    }
                    selection.formIntersection(Set(model.rows.map(\.id)))
                }
            } catch { fileOperationError = error.localizedDescription }
        }
    }

    private func handleFileKeyPress(_ press: KeyPress) -> KeyPress.Result {
        do {
            let item: FileItem? = try node(in: selection).map { try FileItem(entry: $0.entry) }
            let destination: URL = item.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? URL(fileURLWithPath: model.rootPath)
            if press.key == "v", press.modifiers == .command, selection.count <= 1, !operating, !clipboardItems.isEmpty { paste(into: destination); return .handled }
            if press.key == "v", press.modifiers == [.command, .option], selection.count <= 1, !operating, !clipboardItems.isEmpty { move(into: destination); return .handled }
            if press.key == "c", press.modifiers == .command, selection.count > 1 { copySelection(selection); return .handled }
            // macOS Delete sends DEL (0x7f), while SwiftUI's .delete represents backspace (0x08).
            if (press.key == .delete || press.key == KeyEquivalent("\u{7f}")), press.modifiers == .command, !operating,
               selection.contains(where: { if case .node = $0 { return true }; return false }) {
                trashSelection(selection)
                return .handled
            }
            guard let item else { return .ignored }
            if press.key == "o", press.modifiers == .command { open(item); return .handled }
            if press.key == .space, press.modifiers.isEmpty { previewURL = item.url; return .handled }
            if press.key == "c", press.modifiers == .command { copy(item); return .handled }
            if press.key == "c", press.modifiers == [.command, .option] { copyPath(item); return .handled }
            if press.key == .return, press.modifiers.isEmpty, !operating { renaming = item; return .handled }
            if press.key == "d", press.modifiers == .command, !operating { duplicate(item); return .handled }
            return .ignored
        } catch {
            fileOperationError = error.localizedDescription
            return .handled
        }
    }
}

private struct LastOpenedDateCell: View {
    let path: Data
    let operations: FileOperations
    @State private var date: Date?
    @State private var errorMessage: String?

    var body: some View {
        Text(lastOpenedLabel(date))
            .lineLimit(1)
            .help(errorMessage ?? (date == nil ? "Date last opened unavailable" : lastOpenedLabel(date)))
            .task(id: path) {
                do {
                    let opened: Date? = try await operations.lastOpenedDate(path)
                    guard !Task.isCancelled else { return }
                    date = opened
                    errorMessage = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    date = nil
                    errorMessage = error.localizedDescription
                }
            }
    }
}

private func lastOpenedLabel(_ date: Date?) -> String {
    guard let date else { return "-" }
    return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        .replacingOccurrences(of: "\u{a0}", with: " ")
        .replacingOccurrences(of: "\u{202f}", with: " ")
}

private struct RenameItemSheet: View {
    let item: FileItem
    let rename: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(item: FileItem, rename: @escaping (String) -> Void) {
        self.item = item
        self.rename = rename
        _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(item.name)").font(.headline)
            TextField("Name", text: $name).focused($focused)
                .onSubmit { if !name.isEmpty, name != item.name { rename(name) } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") { rename(name) }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || name == item.name)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

struct SizeProportionBar: View {
    let proportion: Double

    var body: some View {
        Gauge(value: proportion, in: ClosedRange<Double>(uncheckedBounds: (lower: 0, upper: 1))) { EmptyView() }
            .gaugeStyle(.linearCapacity)
            .tint(.accentColor)
            .accessibilityLabel("Share of parent folder")
            .accessibilityValue(proportion.formatted(.percent.precision(.fractionLength(1))))
            .allowsHitTesting(false)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

private struct TreeScanStatus: View {
    let model: DiskTreeModel
    let issues: [ScanIssue]
    @Binding var showingIssues: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error: String = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(3).help(error) }
            HStack {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    ProgressView(value: model.scanProgress, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                        .accessibilityLabel("Estimated scan progress")
                        .accessibilityValue(model.scanProgress.formatted(.percent.precision(.fractionLength(0))))
                        .help("Estimated from completed folders")
                    if model.isWaitingForWriter {
                        Text("Waiting for another scan")
                    } else {
                        Text("Scanning - \(model.scannedEntries.formatted()) items observed")
                    }
                } else if model.scanStopped { Text("Scan stopped") }
                else if let summary: IndexSummary = model.summary {
                    Text("\(summary.nodeCount.formatted()) items")
                    Text(fileSize(summary.allocatedBytes) + " allocated").foregroundStyle(.secondary)
                }
                Spacer()
                if !issues.isEmpty {
                    Button("\(issues.count.formatted()) locations unavailable") { showingIssues = true }
                        .buttonStyle(.borderless)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TreeNameCell: View {
    let row: DiskTreeRow
    let model: DiskTreeModel

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            switch row {
            case .more(let directory, _):
                Button("Load more items") { Task { await model.loadMore(directory) } }
                    .buttonStyle(.borderless)
                    .disabled(model.loading.contains(directory))
            case .node(let node, _, _):
                if node.entry.metadata.kind == .directory {
                    Button {
                        Task { await model.toggle(node.entry.path) }
                    } label: {
                        Image(systemName: model.expanded.contains(node.entry.path) ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((model.expanded.contains(node.entry.path) ? "Collapse " : "Expand ") + String(decoding: node.entry.name, as: UTF8.self))
                } else { Color.clear.frame(width: 14, height: 1) }
                Image(systemName: node.entry.metadata.kind == .directory ? "folder" : (node.entry.metadata.kind == .symbolicLink ? "link" : "doc"))
                    .foregroundStyle(node.entry.metadata.kind == .directory ? Color.accentColor : Color.secondary)
                Text(String(decoding: node.entry.name, as: UTF8.self))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(String(decoding: node.entry.path, as: UTF8.self))
                if node.aliasTargetPath != nil { Image(systemName: "arrow.turn.up.right").foregroundStyle(.secondary).help("Filesystem alias") }
            }
        }
    }
}

private func fileSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
