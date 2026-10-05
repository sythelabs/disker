import DiskerCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model: DiskTreeModel
    @State private var selection: DiskTreeRowID?
    @State private var choosingFolder: Bool = false
    @State private var showingIssues: Bool = false
    @State private var folderPickerError: String?

    init(rootURL: URL, cacheURL: URL) {
        _model = State(initialValue: DiskTreeModel(rootURL: rootURL, cacheURL: cacheURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            tree
            Divider()
            TreeScanStatus(model: model, issues: blockingIssues, showingIssues: $showingIssues)
        }
        .frame(minWidth: 740, minHeight: 440)
        .navigationTitle("Disker")
        .navigationSubtitle(model.rootPath)
        .toolbar {
            ToolbarItemGroup {
                Button("Choose Folder", systemImage: "folder") { choosingFolder = true }
                    .help("Choose the root of the file tree")
                if model.isScanning {
                    Button("Stop Scan", systemImage: "stop.fill") { model.cancelScan() }
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                selection = nil
                Task { await model.chooseRoot(url) }
            case .failure(let error):
                folderPickerError = error.localizedDescription
            }
        }
        .alert("Could not choose folder", isPresented: Binding(get: { folderPickerError != nil }, set: { if !$0 { folderPickerError = nil } })) {
            Button("OK", role: .cancel) { folderPickerError = nil }
        } message: { Text(folderPickerError ?? "") }
        .alert("Some locations could not be read", isPresented: $showingIssues) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockingIssues.prefix(20).map { "\(String(decoding: $0.path, as: UTF8.self)): \($0.operation), error \($0.errnoCode)" }.joined(separator: "\n"))
        }
        .task { await model.start() }
        .onDisappear { model.cancelScan() }
    }

    private var tree: some View {
        Table(model.rows, selection: $selection) {
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
            } else if let path: Data = directory(in: ids) {
                Button(model.expanded.contains(path) ? "Collapse Folder" : "Expand Folder") { Task { await model.toggle(path) } }
            }
        } primaryAction: { ids in
            if case .more(let path) = ids.first { Task { await model.loadMore(path) } }
            else if let path: Data = directory(in: ids) { Task { await model.toggle(path) } }
        }
        .onKeyPress(.rightArrow) {
            guard case .node(let path) = selection,
                  let row: DiskTreeRow = model.rows.first(where: { $0.id == selection }),
                  row.node?.entry.metadata.kind == .directory else { return .ignored }
            if model.expanded.contains(path) {
                if let child: DiskTreeRow = model.rows.first(where: { $0.node?.entry.parentPath == path }) { selection = child.id }
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
        .overlay {
            if model.rows.isEmpty {
                if model.isScanning {
                    VStack(spacing: 12) { ProgressView(); Text("Reading file tree").foregroundStyle(.secondary) }
                } else {
                    ContentUnavailableView(model.scanStopped ? "Scan stopped" : "No indexed files", systemImage: "folder", description: Text("Choose a folder or refresh to read its file tree."))
                }
            }
        }
    }

    private var blockingIssues: [ScanIssue] {
        model.summary?.issues.filter { ![.excluded, .directoryAlias, .mountBoundary].contains($0.kind) } ?? []
    }

    private func directory(in ids: Set<DiskTreeRowID>) -> Data? {
        guard let id: DiskTreeRowID = ids.first, let row: DiskTreeRow = model.rows.first(where: { $0.id == id }),
              let node: IndexedNode = row.node, node.entry.metadata.kind == .directory else { return nil }
        return node.entry.path
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
                    Text("Scanning - \(model.scannedEntries.formatted()) items observed")
                    Text("Sizes are preliminary").foregroundStyle(.secondary)
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
