import Foundation

// MARK: - NDJSON framing

/// Splits a byte stream into `\n`-terminated JSON lines. Tolerates `\r\n` and blank lines.
public struct NDJSONFramer: Sendable {
    private var buffer = Data()
    /// Lines longer than this are dropped (protects against a runaway peer).
    public var maxLineBytes: Int

    public init(maxLineBytes: Int = 16 * 1024 * 1024) { self.maxLineBytes = maxLineBytes }

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty, !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { lines.append(Data(line)) }
            buffer = Data(buffer[(nl + 1)...])
        }
        if buffer.count > maxLineBytes { buffer.removeAll(keepingCapacity: false) }
        return lines
    }

    public var pendingBytes: Int { buffer.count }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder.rpc.encode(value)
        data.append(0x0A)
        return data
    }
}

extension JSONEncoder {
    public static var rpc: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

// MARK: - Envelopes

public struct EmptyParams: Codable, Sendable { public init() {} }

public struct RPCRequest<P: Encodable>: Encodable {
    public let jsonrpc = "2.0"
    public let id: Int
    public let method: String
    public let params: P
    public init(id: Int, method: String, params: P) { self.id = id; self.method = method; self.params = params }
    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
}

public struct RPCErrorPayload: Codable, Error, Equatable, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) { self.code = code; self.message = message; self.data = data }

    public var errorDescription: String? { message }

    public static let parse = -32700
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let notAuthenticated = -32001
    public static let notFound = -32010
    public static let conflict = -32011
    public static let providerAuth = -32012
    public static let blockedByPolicy = -32013
}

/// The routing-relevant parts of any incoming line.
public struct RPCHead: Decodable, Sendable {
    public var id: Int?
    public var method: String?
    public var error: RPCErrorPayload?

    enum CodingKeys: String, CodingKey { case id, method, error }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decodeIfPresent(Int.self, forKey: .id) { id = i }
        else if let s = try? c.decodeIfPresent(String.self, forKey: .id) { id = Int(s) }
        else { id = nil }
        method = try c.decodeIfPresent(String.self, forKey: .method)
        error = try c.decodeIfPresent(RPCErrorPayload.self, forKey: .error)
    }
}

struct ResultBox<R: Decodable>: Decodable { let result: R }
struct ParamsBox<P: Decodable>: Decodable { let params: P }

public enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case timeout(String)
    case connectionClosed
    case decoding(String)
    case socket(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return L("The sync service isn't connected.")
        case .timeout(let m): return L("The sync service didn't answer %@ in time.", m)
        case .connectionClosed: return L("The connection to the sync service closed.")
        case .decoding(let m): return L("Unexpected reply from the sync service: %@", m)
        case .socket(let m): return m
        }
    }
}

// MARK: - Notifications

public enum DaemonEvent: Sendable {
    case connection(ConnectionState)
    case jobState(JobStateNote)
    case jobProgress(JobProgressNote)
    case overall(OverallProgress)
    case actionNew(Action)
    case actionUpdated(Action)
    case logLine(LogLine)
    case health(HealthNote)
    case preview(PreviewNote)
    case other(method: String)

    /// Decodes a notification line by method name. Unknown methods are passed through as `.other`.
    public static func decode(method: String, line: Data) -> DaemonEvent? {
        let d = JSONDecoder()
        func p<T: Decodable>(_ t: T.Type) -> T? { try? d.decode(ParamsBox<T>.self, from: line).params }
        switch method {
        case "job.state": return p(JobStateNote.self).map(DaemonEvent.jobState)
        case "job.progress": return p(JobProgressNote.self).map(DaemonEvent.jobProgress)
        case "overall.progress": return p(OverallProgress.self).map(DaemonEvent.overall)
        case "action.new": return p(ActionNote.self).map { .actionNew($0.action) }
        case "action.updated": return p(ActionNote.self).map { .actionUpdated($0.action) }
        case "log.line": return p(LogLineNote.self).map { .logLine($0.line) }
        case "daemon.health": return p(HealthNote.self).map(DaemonEvent.health)
        case "job.preview": return p(PreviewNote.self).map(DaemonEvent.preview)
        default: return .other(method: method)
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case connected(HelloResult)
    case disconnected(String)

    public var isConnected: Bool { if case .connected = self { return true }; return false }
}
