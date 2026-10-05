import DiskerCore
import Foundation
import Testing
@testable import Disker

@Suite("Writer waiting status")
struct WriterWaitingTests {
    @Test func waitingStatusClearsWhenWriterIsAcquired() {
        let buffer: TreeScanBuffer = TreeScanBuffer(root: Data("/fixture".utf8), capturePreview: false, limit: 500)
        buffer.receive(.started(cached: nil))
        #expect(!buffer.snapshot().isWaitingForWriter)
        buffer.receive(.waitingForWriter)
        #expect(buffer.snapshot().isWaitingForWriter)
        buffer.receive(.writerAcquired)
        #expect(!buffer.snapshot().isWaitingForWriter)
    }

    @Test func cancellationClearsWaitingStatusAndRejectsLateWaitingEvents() {
        let buffer: TreeScanBuffer = TreeScanBuffer(root: Data("/fixture".utf8), capturePreview: false, limit: 500)
        buffer.receive(.waitingForWriter)
        #expect(buffer.snapshot().isWaitingForWriter)
        buffer.cancel()
        #expect(buffer.isCancelled)
        #expect(!buffer.snapshot().isWaitingForWriter)
        buffer.receive(.waitingForWriter)
        #expect(!buffer.snapshot().isWaitingForWriter)
    }
}
