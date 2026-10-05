import CoreFoundation
import CoreServices
import Foundation

public enum NodeSortColumn: Hashable, Sendable {
    case name
    case sizeProportion
    case allocatedSize
    case lastOpened
    case items
}

public struct NodeSort: SortComparator, Sendable {
    public let column: NodeSortColumn
    public var order: SortOrder

    public init(column: NodeSortColumn, order: SortOrder) {
        self.column = column
        self.order = order
    }

    public func compare(_ lhs: IndexedNode, _ rhs: IndexedNode) -> ComparisonResult {
        let result: ComparisonResult
        switch column {
        case .name:
            result = compareNodeNames(lhs, rhs)
        case .allocatedSize, .sizeProportion:
            if lhs.subtreeAllocatedBytes == rhs.subtreeAllocatedBytes { return compareNodeNames(lhs, rhs) }
            result = lhs.subtreeAllocatedBytes < rhs.subtreeAllocatedBytes ? .orderedAscending : .orderedDescending
        case .items:
            if lhs.itemCount == rhs.itemCount { return compareNodeNames(lhs, rhs) }
            result = lhs.itemCount < rhs.itemCount ? .orderedAscending : .orderedDescending
        case .lastOpened:
            switch (lhs.lastOpenedDate, rhs.lastOpenedDate) {
            case (.none, .none): return compareNodeNames(lhs, rhs)
            case (.none, .some): return .orderedDescending
            case (.some, .none): return .orderedAscending
            case (.some(let left), .some(let right)):
                if left == right { return compareNodeNames(lhs, rhs) }
                result = left < right ? .orderedAscending : .orderedDescending
            }
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

private func compareNodeNames(_ lhs: IndexedNode, _ rhs: IndexedNode) -> ComparisonResult {
    let result: ComparisonResult = String(decoding: lhs.entry.name, as: UTF8.self)
        .localizedStandardCompare(String(decoding: rhs.entry.name, as: UTF8.self))
    if result != .orderedSame { return result }
    if lhs.entry.name != rhs.entry.name {
        return lhs.entry.name.lexicographicallyPrecedes(rhs.entry.name) ? .orderedAscending : .orderedDescending
    }
    if lhs.entry.path == rhs.entry.path { return .orderedSame }
    return lhs.entry.path.lexicographicallyPrecedes(rhs.entry.path) ? .orderedAscending : .orderedDescending
}

public func fileLastOpenedDate(path: Data) throws -> Date? {
    guard path.first == 47, !path.contains(0) else {
        throw IndexError.invalidQuery("Invalid path for date last opened: \(String(decoding: path, as: UTF8.self))")
    }
    let native: CFURL? = path.withUnsafeBytes {
        CFURLCreateFromFileSystemRepresentation(nil, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), path.count, false)
    }
    guard let native else { throw IndexError.invalidQuery("Could not create URL for date last opened: \(String(decoding: path, as: UTF8.self))") }
    guard let item: MDItem = MDItemCreateWithURL(nil, native),
          let value: CFTypeRef = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
    guard let date: Date = value as? Date else {
        throw IndexError.invalidQuery("Spotlight returned an unexpected date last opened type for \(String(decoding: path, as: UTF8.self))")
    }
    return date
}
