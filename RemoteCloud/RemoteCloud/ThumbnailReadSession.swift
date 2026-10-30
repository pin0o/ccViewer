import Foundation

public enum ThumbnailReadError: Error {
    case limitExceeded, unsupported, invalidData, textFile
}

/// Task-local policy: normal playback keeps its existing buffering and cancellation.
final class ThumbnailReadScope: @unchecked Sendable {
    @TaskLocal static var current: ThumbnailReadScope?
    private let lock = NSLock()
    private var cancelled = false
    private var remaining: Int
    private let deadline: Date
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    init(maximumBytes: Int, timeout: TimeInterval) {
        remaining = maximumBytes
        deadline = Date().addingTimeInterval(timeout)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let runNow = cancelled
        if !runNow { handlers[id] = handler }
        lock.unlock()
        if runNow { handler() }
        return id
    }

    func removeHandler(_ id: UUID) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }

    func check() throws {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if deadline <= Date() || remaining < 0 { throw ThumbnailReadError.limitExceeded }
    }

    func consume(_ count: Int) throws {
        try check()
        lock.lock()
        defer { lock.unlock() }
        remaining -= count
        if remaining < 0 { throw ThumbnailReadError.limitExceeded }
    }

    var timeRemaining: TimeInterval { max(0.1, deadline.timeIntervalSinceNow) }
}

/// Owns a separate stream; closing it never cancels the storage service.
public actor ThumbnailReadSession {
    private let stream: RemoteStream
    private nonisolated let scope: ThumbnailReadScope
    public nonisolated let size: Int64
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(stream: RemoteStream, scope: ThumbnailReadScope) {
        self.stream = stream
        self.scope = scope
        size = stream.size
    }

    public nonisolated func cancel() { scope.cancel() }
    public nonisolated func check() throws { try scope.check() }
    public nonisolated var timeRemaining: TimeInterval { scope.timeRemaining }
    public nonisolated func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID { scope.onCancel(handler) }
    public nonisolated func removeCancellationHandler(_ id: UUID) { scope.removeHandler(id) }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiting.isEmpty { busy = false }
        else { waiting.removeFirst().resume() }
    }

    public func read(position: Int64, length: Int) async throws -> Data {
        // Actor reentrancy must not interleave reads on mutable crypto/slot streams.
        await acquire()
        defer { release() }
        try scope.check()
        guard position >= 0, length >= 0 else { throw ThumbnailReadError.invalidData }
        if position >= size || length == 0 { return Data() }
        return try await ThumbnailReadScope.$current.withValue(scope) {
            guard let data = try await stream.read(position: position, length: length) else {
                try scope.check()
                throw ThumbnailReadError.invalidData
            }
            try scope.check()
            return data
        }
    }

    public func close() async {
        scope.cancel()
        await acquire()
        defer { release() }
        await stream.close()
    }
}

extension RemoteItem {
    public func openThumbnail(maximumBytes: Int, timeout: TimeInterval = 10) async throws -> ThumbnailReadSession {
        let scope = ThumbnailReadScope(maximumBytes: maximumBytes, timeout: timeout)
        let stream = await ThumbnailReadScope.$current.withValue(scope) { await self.open() }
        do {
            try scope.check()
            guard stream.size > 0 else { throw ThumbnailReadError.invalidData }
            return ThumbnailReadSession(stream: stream, scope: scope)
        } catch {
            scope.cancel()
            await stream.close()
            throw error
        }
    }
}

extension URLSession {
    /// Streaming response prevents a server that ignores Range from downloading a whole movie.
    func thumbnailData(for request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        guard let scope = ThumbnailReadScope.current else { return try await data(for: request, delegate: delegate) }
        try scope.check()
        var bounded = request
        bounded.timeoutInterval = min(request.timeoutInterval, scope.timeRemaining)
        let (bytes, response) = try await self.bytes(for: bounded, delegate: delegate)
        if request.value(forHTTPHeaderField: "Range") != nil,
           (response as? HTTPURLResponse)?.statusCode != 206 {
            scope.cancel()
            throw ThumbnailReadError.unsupported
        }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            scope.cancel()
            throw ThumbnailReadError.invalidData
        }
        var data = Data()
        var chunk = Data()
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 16 * 1024 {
                try scope.consume(chunk.count)
                data.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try scope.consume(chunk.count)
        data.append(chunk)
        return (data, response)
    }
}

public extension Notification.Name {
    static let thumbnailInvalidated = Notification.Name("RemoteCloud.thumbnailInvalidated")
}
