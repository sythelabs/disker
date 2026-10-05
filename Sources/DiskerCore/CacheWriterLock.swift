import Darwin
import Foundation

enum CacheWriterLockError: Error, Sendable, LocalizedError {
    case systemCall(path: String, operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .systemCall(let path, let operation, let code):
            return "Cache writer lock failed at \(path): \(operation), error \(code), \(String(cString: strerror(code)))"
        }
    }
}

func bootstrapCacheWithWriterLock(at url: URL, isReady: () throws -> Bool, bootstrap: () throws -> Void) throws {
    let descriptor: Int32 = url.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR) }
    guard descriptor >= 0 else { throw CacheWriterLockError.systemCall(path: url.path, operation: "open", code: errno) }
    let result: Result<Void, any Error>
    do {
        while true {
            if Task.isCancelled { throw ScanError.cancelled }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try bootstrap()
                break
            }
            let code: Int32 = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else { throw CacheWriterLockError.systemCall(path: url.path, operation: "flock", code: code) }
            if try isReady() { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        result = .success(())
    } catch {
        result = .failure(error)
    }
    guard close(descriptor) == 0 else { throw CacheWriterLockError.systemCall(path: url.path, operation: "close", code: errno) }
    try result.get()
}

func withCacheWriterLock<Value: Sendable>(
    at url: URL,
    isCancelled: @escaping @Sendable () -> Bool,
    onWait: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let descriptor: Int32 = url.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR) }
    guard descriptor >= 0 else { throw CacheWriterLockError.systemCall(path: url.path, operation: "open", code: errno) }
    let result: Result<Value, any Error>
    do {
        var notified: Bool = false
        while true {
            if isCancelled() || Task.isCancelled { throw ScanError.cancelled }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            let code: Int32 = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else { throw CacheWriterLockError.systemCall(path: url.path, operation: "flock", code: code) }
            if !notified { onWait(); notified = true }
            try await Task.sleep(for: .milliseconds(50))
        }
        if isCancelled() || Task.isCancelled { throw ScanError.cancelled }
        result = .success(try await operation())
    } catch is CancellationError {
        result = .failure(ScanError.cancelled)
    } catch {
        result = .failure(error)
    }
    guard close(descriptor) == 0 else { throw CacheWriterLockError.systemCall(path: url.path, operation: "close", code: errno) }
    return try result.get()
}
