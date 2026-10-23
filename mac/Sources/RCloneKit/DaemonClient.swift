import Foundation

/// JSON-RPC 2.0 client for `pdrcloned` (docs/PROTOCOL.md).
/// - Sends `hello` first, then `subscribe`, on every (re)connect.
/// - Reconnects with exponential backoff (0.25 s → 10 s) until `stop()`.
/// - All notifications and connection changes arrive on `events`.
public actor DaemonClient {
    public nonisolated let events: AsyncStream<DaemonEvent>
    private let eventSink: AsyncStream<DaemonEvent>.Continuation

    public nonisolated let socketPath: String
    private let clientVersion: String
    private var topics: [String]

    private var connection: UnixSocketConnection?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var loopTask: Task<Void, Never>?
    private var stopped = false
    public private(set) var state: ConnectionState = .idle
    public private(set) var hello: HelloResult?

    /// Called before each connection attempt (attempt number starting at 1). Used to start the daemon.
    private var beforeConnect: (@Sendable (Int) async -> Void)?

    public init(socketPath: String, clientVersion: String, topics: [String] = Topic.defaults) {
        self.socketPath = socketPath
        self.clientVersion = clientVersion
        self.topics = topics
        (events, eventSink) = AsyncStream.makeStream(of: DaemonEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    public func setBeforeConnect(_ hook: (@Sendable (Int) async -> Void)?) { beforeConnect = hook }

    public func start() {
        guard loopTask == nil else { return }
        stopped = false
        loopTask = Task { await self.runLoop() }
    }

    public func stop() {
        stopped = true
        loopTask?.cancel()
        loopTask = nil
        connection?.close()
        connection = nil
        failAll(ClientError.connectionClosed)
        setState(.idle)
    }

    /// Drop the current connection and reconnect immediately (e.g. after restarting the daemon).
    public func reconnect() {
        connection?.close()
    }

    // MARK: Public API

    public func call<P: Encodable & Sendable, R: Decodable>(_ method: String, _ params: P, as: R.Type = R.self, timeout: TimeInterval = 30) async throws -> R {
        let data = try await raw(method, params, timeout: timeout)
        do {
            return try JSONDecoder().decode(ResultBox<R>.self, from: data).result
        } catch {
            throw ClientError.decoding("\(method): \(error)")
        }
    }

    public func call<R: Decodable>(_ method: String, as: R.Type = R.self, timeout: TimeInterval = 30) async throws -> R {
        try await call(method, EmptyParams(), as: R.self, timeout: timeout)
    }

    /// For methods whose result shape we don't care about (`{ok:true}`, `{}`, `null`).
    public func send<P: Encodable & Sendable>(_ method: String, _ params: P, timeout: TimeInterval = 30) async throws {
        _ = try await raw(method, params, timeout: timeout)
    }

    public func send(_ method: String, timeout: TimeInterval = 30) async throws {
        _ = try await raw(method, EmptyParams(), timeout: timeout)
    }

    /// Updates the topics re-sent on reconnect without contacting the daemon.
    public func setTopics(_ newTopics: [String]) { topics = newTopics }

    public func updateSubscriptions(_ newTopics: [String]) async throws {
        topics = newTopics
        guard state.isConnected else { return }
        try await send("subscribe", SubscribeParams(topics: newTopics))
    }

    // MARK: Internals

    private func raw<P: Encodable & Sendable>(_ method: String, _ params: P, timeout: TimeInterval, requireConnected: Bool = true) async throws -> Data {
        guard let connection, !requireConnected || state.isConnected || method == "hello" || method == "subscribe" else {
            throw ClientError.notConnected
        }
        let id = nextID
        nextID += 1
        let frame = try NDJSONFramer.encode(RPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[id] = cont
            do {
                try connection.send(frame)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id, method: method)
            }
        }
    }

    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: ClientError.timeout(method))
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c.resume(throwing: error) }
    }

    private func setState(_ s: ConnectionState) {
        guard s != state else { return }
        state = s
        eventSink.yield(.connection(s))
    }

    private func runLoop() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            attempt += 1
            setState(.connecting(attempt: attempt))
            if let hook = beforeConnect { await hook(attempt) }
            if stopped { break }
            do {
                let conn = try UnixSocketConnection(path: socketPath)
                connection = conn
                let reader = Task { await self.readLoop(conn) }
                let helloData = try await raw("hello", HelloParams(version: clientVersion), timeout: 10, requireConnected: false)
                let result = try JSONDecoder().decode(ResultBox<HelloResult>.self, from: helloData).result
                hello = result
                _ = try? await raw("subscribe", SubscribeParams(topics: topics), timeout: 10, requireConnected: false)
                attempt = 0
                setState(.connected(result))
                await reader.value
                // Connection ended.
                connection = nil
                failAll(ClientError.connectionClosed)
                if !stopped { setState(.disconnected(L("The sync service stopped responding."))) }
            } catch {
                connection?.close()
                connection = nil
                failAll(ClientError.connectionClosed)
                if !stopped { setState(.disconnected(error.localizedDescription)) }
            }
            if stopped { break }
            let delay = Self.backoff(attempt: max(attempt, 1))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// 0.25, 0.5, 1, 2, 4, 8, 10, 10 … seconds.
    public static func backoff(attempt: Int) -> TimeInterval {
        min(10, 0.25 * pow(2, Double(max(0, attempt - 1))))
    }

    private func readLoop(_ conn: UnixSocketConnection) async {
        for await line in conn.lines {
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let head = try? JSONDecoder().decode(RPCHead.self, from: line) else { return }
        if let id = head.id, head.method == nil {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error = head.error { cont.resume(throwing: error) } else { cont.resume(returning: line) }
            return
        }
        if let method = head.method, let event = DaemonEvent.decode(method: method, line: line) {
            eventSink.yield(event)
        }
    }
}

// MARK: - Socket location

public enum DaemonPaths {
    public static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PigmentDev rClone", isDirectory: true)
    }

    public static var defaultSocket: String { appSupport.appendingPathComponent("daemon.sock").path }

    /// `PDRCLONE_SOCKET` wins, then `PDRCLONE_HOME/daemon.sock`, then the default.
    public static func resolveSocket(environment: [String: String] = ProcessInfo.processInfo.environment) -> (path: String, overridden: Bool) {
        if let s = environment["PDRCLONE_SOCKET"], !s.isEmpty { return ((s as NSString).expandingTildeInPath, true) }
        if let h = environment["PDRCLONE_HOME"], !h.isEmpty {
            return (((h as NSString).expandingTildeInPath as NSString).appendingPathComponent("daemon.sock"), true)
        }
        return (defaultSocket, false)
    }
}
