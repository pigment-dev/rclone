import Darwin
import Foundation

/// A connected AF_UNIX stream socket that delivers NDJSON lines as an AsyncStream.
/// Reads use a DispatchSource on a private queue (no polling, no busy threads while idle).
public final class UnixSocketConnection: @unchecked Sendable {
    public let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.pigmentdev.rclone.socket")
    private var source: DispatchSourceRead?
    private var framer = NDJSONFramer()
    private var closed = false

    /// Connects synchronously (local sockets connect instantly or fail).
    public init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socket("socket() failed: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < maxLen else {
            Darwin.close(fd)
            throw ClientError.socket("Socket path is too long (\(bytes.count) bytes, max \(maxLen - 1)).")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ClientError.socket("connect(\(path)) failed: \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        start()
    }

    private func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        source = src
        src.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                for line in framer.append(Data(buf[0..<n])) { continuation.yield(line) }
                if n < buf.count { return }
            } else if n == 0 {
                closeOnQueue(); return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                closeOnQueue(); return
            }
        }
    }

    /// Writes one already-framed message. Thread-safe; blocks only the socket queue.
    public func send(_ data: Data) throws {
        var failure: Error?
        queue.sync {
            guard !closed else { failure = ClientError.connectionClosed; return }
            var offset = 0
            data.withUnsafeBytes { raw in
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EAGAIN || errno == EINTR {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 1000)
                        continue
                    }
                    failure = ClientError.socket("write failed: \(String(cString: strerror(errno)))")
                    return
                }
            }
        }
        if let failure { throw failure }
    }

    public func close() { queue.async { self.closeOnQueue() } }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        continuation.finish()
    }

    deinit {
        if !closed { source?.cancel() }
    }
}

/// True when something is accepting connections at `path`.
public func isSocketReachable(_ path: String) -> Bool {
    guard let c = try? UnixSocketConnection(path: path) else { return false }
    c.close()
    return true
}
