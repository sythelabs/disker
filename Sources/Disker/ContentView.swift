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
    @State private var selection: DiskTreeRowID?
    @State private var searchText: String = ""
    @State private var choosingFolder: Bool = false
    @State private var showingIssues: Bool = false
    @State private var folderPickerError: String?
    @State private var fileOperationError: String?
    @State private var folderStarError: String?
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
                    Button(locations.isStarred(rootURL) ? "Unstar Folder" : "Star Folder", systemImage: locations.isStarred(rootURL) ? "star.fill" : "star") {
                        toggleStar(rootURL)
                    }
                    .help("Keep this folder in the sidebar")
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
        .alert("Could not star folder", isPresented: Binding(get: { folderStarError != nil }, set: { if !$0 { folderStarError = nil } })) {
            Button("OK", role: .cancel) { folderStarError = nil }
        } message: { Text(folderStarError ?? "") }
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
            selection = nil
            searchText = ""
        }
        .onChange(of: searchText) { _, _ in selection = nil }
    }

    private var tree: some View {
        Table(visibleRows, selection: $selection) {
            TableColumn("Name") { row in
                TreeNameCell(row: row, model: model)
            }
            .width(min: CGFloat((model.rows.map(\.depth).max() ?? 0) * 16 + 300), ideal: 440, max: .infinity)
            TableColumn("Size proportion") { row in
                if let proportion: Double = row.proportion {
                    SizeProportionBar(proportion: proportion)
                }
            }
            .width(min: 150, ideal: 180, max: 300)
            TableColumn("Parent %") { row in
                if let proportion: Double = row.proportion {
                    Text(proportion.formatted(.percent.precision(.fractionLength(1))))
                        .monospacedDigit()
                }
            }
            .width(min: 85, ideal: 95, max: 120)
            .alignment(.trailing)
            TableColumn("Allocated size") { row in
                if let node: IndexedNode = row.node { Text(fileSize(node.subtreeAllocatedBytes)).monospacedDigit() }
            }
            .width(min: 120, ideal: 130, max: 180)
            .alignment(.trailing)
            TableColumn("Logical size") { row in
                if let node: IndexedNode = row.node { Text(fileSize(node.subtreeLogicalBytes)).monospacedDigit() }
            }
            .width(min: 120, ideal: 130, max: 180)
            .alignment(.trailing)
            TableColumn("Items") { row in
                if let node: IndexedNode = row.node {
                    Text((node.entry.metadata.kind == .directory ? max(0, node.subtreeNodeCount - 1) : 1).formatted())
                        .monospacedDigit()
                }
            }
            .width(min: 75, ideal: 90, max: 140)
            .alignment(.trailing)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: DiskTreeRowID.self) { ids in
            if case .more(let path) = ids.first {
                Button("Load more items") { Task { await model.loadMore(path) } }
            } else if let node: IndexedNode = node(in: ids) {
                switch Result(catching: { try FileItem(entry: node.entry) }) {
                case .success(let item): fileMenu(item)
                case .failure(let error): Button("Could not access item") { fileOperationError = error.localizedDescription }
                }
            } else {
                pasteMenu(into: URL(fileURLWithPath: model.rootPath))
            }
        } primaryAction: { ids in
            if case .more(let path) = ids.first { Task { await model.loadMore(path) } }
            else if let node: IndexedNode = node(in: ids) {
                do { open(try FileItem(entry: node.entry)) }
                catch { fileOperationError = error.localizedDescription }
            }
        }
        .onKeyPress(.rightArrow) {
            guard case .node(let path) = selection,
                  let row: DiskTreeRow = model.rows.first(where: { $0.id == selection }),
                  row.node?.entry.metadata.kind == .directory else { return .ignored }
            if model.expanded.contains(path) {
                if let child: DiskTreeRow = visibleRows.first(where: { $0.node?.entry.parentPath == path }) { selection = child.id }
            } else { Task { await model.toggle(path) } }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard case .node(let path) = selection,
                  let row: DiskTreeRow = model.rows.first(where: { $0.id == selection }) else { return .ignored }
            if model.expanded.contains(path) { Task { await model.toggle(path) } }
            else if let parent: Data = row.node?.entry.parentPath { selection = .node(parent) }
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

    private var rootURL: URL { URL(fileURLWithPath: model.rootPath) }

    private var rootTitle: String { model.rootPath == "/" ? "File System" : rootURL.lastPathComponent }

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: {
                let destinations: [SidebarSelection] = locations.favorites.map { SidebarSelection(section: .favorites, path: $0.id) }
                    + locations.starred.map { SidebarSelection(section: .starred, path: $0.id) }
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
        selection = nil
        Task { await model.chooseRoot(url) }
    }

    private func toggleStar(_ url: URL) {
        if locations.isStarred(url) { locations.unstar(url) }
        else {
            Task {
                do { try await locations.star(url) }
                catch { folderStarError = error.localizedDescription }
            }
        }
    }

    private func node(in ids: Set<DiskTreeRowID>) -> IndexedNode? {
        guard let id: DiskTreeRowID = ids.first else { return nil }
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
            Button(locations.isStarred(item.url) ? "Unstar Folder" : "Star Folder", systemImage: locations.isStarred(item.url) ? "star.fill" : "star") {
                toggleStar(item.url)
            }
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
        Button("Move to Trash", systemImage: "trash", role: .destructive) { trash(item) }
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
                    selection = nil
                    await model.chooseRoot(item.url)
                } else { try await operations.open(item) }
            } catch { fileOperationError = error.localizedDescription }
        }
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
            return FileChange(removedURL: item.url, insertedURL: destination)
        }
    }

    private func duplicate(_ item: FileItem) {
        performMutation(in: [item.url.deletingLastPathComponent()]) {
            let destination: URL = try await operations.duplicate(item)
            return FileChange(removedURL: nil, insertedURL: destination)
        }
    }

    private func trash(_ item: FileItem) {
        performMutation(in: [item.url.deletingLastPathComponent()]) {
            _ = try await operations.trash(item)
            return FileChange(removedURL: item.url, insertedURL: nil)
        }
    }

    private func paste(into directory: URL) {
        let sources: [URL]
        do { sources = try operations.files(on: .general) }
        catch { fileOperationError = error.localizedDescription; return }
        performMutation(in: [directory]) {
            var destination: URL?
            guard !sources.isEmpty else { throw FileOperationError.failed("Paste", directory, "No files on the clipboard") }
            for source: URL in sources { destination = try await operations.paste(source, into: directory) }
            return FileChange(removedURL: nil, insertedURL: destination)
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
            return FileChange(removedURL: sources.last, insertedURL: destination)
        }
    }

    private func performMutation(in directories: [URL], operation: @escaping @MainActor () async throws -> FileChange) {
        guard !operating else { return }
        operating = true
        let originalRoot: String = model.rootPath
        let originalSelection: DiskTreeRowID? = selection
        Task {
            defer { operating = false }
            var change: FileChange?
            do { change = try await operation() }
            catch { fileOperationError = error.localizedDescription }
            do {
                let root: Data = Data(model.rootPath.utf8)
                if let removed: URL = change?.removedURL, try filePathBytes(removed) == root {
                    selection = nil
                    await model.chooseRoot(change?.insertedURL ?? removed.deletingLastPathComponent())
                } else {
                    let prefix: Data = root.last == 47 ? root : root + Data([47])
                    let paths: [Data] = try directories.map(filePathBytes).filter { $0 == root || $0.starts(with: prefix) }
                    if !paths.isEmpty { await model.refreshDirectories(paths) }
                    if model.rootPath == originalRoot, selection == originalSelection {
                        if let inserted: URL = change?.insertedURL {
                            let id: DiskTreeRowID = .node(try filePathBytes(inserted))
                            if model.rows.contains(where: { $0.id == id }) { selection = id }
                        } else if let removed: URL = change?.removedURL, selection == .node(try filePathBytes(removed)) { selection = nil }
                    }
                }
            } catch { fileOperationError = error.localizedDescription }
        }
    }

    private func handleFileKeyPress(_ press: KeyPress) -> KeyPress.Result {
        do {
            let item: FileItem? = try selection.flatMap { id in
                guard let entry: ScanEntry = node(in: [id])?.entry else { return nil }
                return try FileItem(entry: entry)
            }
            let destination: URL = item.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? URL(fileURLWithPath: model.rootPath)
            if press.key == "v", press.modifiers == .command, !operating, !clipboardItems.isEmpty { paste(into: destination); return .handled }
            if press.key == "v", press.modifiers == [.command, .option], !operating, !clipboardItems.isEmpty { move(into: destination); return .handled }
            guard let item else { return .ignored }
            if press.key == "o", press.modifiers == .command { open(item); return .handled }
            if press.key == .space, press.modifiers.isEmpty { previewURL = item.url; return .handled }
            if press.key == "c", press.modifiers == .command { copy(item); return .handled }
            if press.key == "c", press.modifiers == [.command, .option] { copyPath(item); return .handled }
            if press.key == .return, press.modifiers.isEmpty, !operating { renaming = item; return .handled }
            if press.key == "d", press.modifiers == .command, !operating { duplicate(item); return .handled }
            // macOS Delete sends DEL (0x7f), while SwiftUI's .delete represents backspace (0x08).
            if (press.key == .delete || press.key == KeyEquivalent("\u{7f}")), press.modifiers == .command, !operating { trash(item); return .handled }
            return .ignored
        } catch {
            fileOperationError = error.localizedDescription
            return .handled
        }
    }
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
                    if model.isWaitingForWriter {
                        Text("Waiting for another scan")
                    } else {
                        Text("Scanning - \(model.scannedEntries.formatted()) items observed")
                        Text("Sizes are preliminary").foregroundStyle(.secondary)
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
