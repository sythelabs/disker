import Foundation

private let fileKinds: [FileKind] = [.regularFile, .directory, .symbolicLink, .socket, .fifo, .characterDevice, .blockDevice, .unknown]

func encodeMetadata(_ metadata: FileMetadata) -> Data {
    let words: [UInt64] = [
        UInt64(fileKinds.firstIndex(of: metadata.kind)!), metadata.device, metadata.inode,
        UInt64(metadata.linkCount), UInt64(metadata.mode), UInt64(metadata.ownerID), UInt64(metadata.groupID),
        metadata.logicalBytes, metadata.allocatedBytes,
        UInt64(bitPattern: metadata.birthTime.seconds), UInt64(metadata.birthTime.nanoseconds),
        UInt64(bitPattern: metadata.modificationTime.seconds), UInt64(metadata.modificationTime.nanoseconds),
        UInt64(bitPattern: metadata.changeTime.seconds), UInt64(metadata.changeTime.nanoseconds),
        UInt64(bitPattern: metadata.accessTime.seconds), UInt64(metadata.accessTime.nanoseconds), UInt64(metadata.flags)
    ].map { $0.littleEndian }
    return words.withUnsafeBytes { Data($0) }
}

func decodeMetadata(_ data: Data) throws -> FileMetadata {
    guard data.count == 144 else { throw IndexError.malformedCache("Invalid metadata record length: \(data.count)") }
    let words: [UInt64] = data.withUnsafeBytes { bytes in
        (0..<18).map { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
    }
    guard words[0] < fileKinds.count,
          [3, 4, 5, 6, 17].allSatisfy({ words[$0] <= UInt32.max }),
          [10, 12, 14, 16].allSatisfy({ words[$0] < 1_000_000_000 }) else {
        throw IndexError.malformedCache("Invalid metadata fields")
    }
    return FileMetadata(kind: fileKinds[Int(words[0])], device: words[1], inode: words[2], linkCount: UInt32(words[3]), mode: UInt32(words[4]), ownerID: UInt32(words[5]), groupID: UInt32(words[6]), logicalBytes: words[7], allocatedBytes: words[8], birthTime: FileTimestamp(seconds: Int64(bitPattern: words[9]), nanoseconds: Int32(words[10])), modificationTime: FileTimestamp(seconds: Int64(bitPattern: words[11]), nanoseconds: Int32(words[12])), changeTime: FileTimestamp(seconds: Int64(bitPattern: words[13]), nanoseconds: Int32(words[14])), accessTime: FileTimestamp(seconds: Int64(bitPattern: words[15]), nanoseconds: Int32(words[16])), flags: UInt32(words[17]))
}

func indexedNode(_ row: RowData) throws -> IndexedNode {
    IndexedNode(entry: ScanEntry(path: row.path, parentPath: row.parent, name: row.name, metadata: try decodeMetadata(row.metadata)), subtreeLogicalBytes: UInt64(row.logical), subtreeAllocatedBytes: UInt64(row.allocated), subtreeNodeCount: row.count, aliasTargetPath: row.aliasTarget)
}

struct RowData {
    let path: Data
    let parent: Data?
    let name: Data
    let metadata: Data
    let logical: Int64
    let allocated: Int64
    let count: Int64
    let aliasTarget: Data?
}
