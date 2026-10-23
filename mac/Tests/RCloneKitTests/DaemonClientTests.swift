import Foundation
import XCTest
@testable import RCloneKit

/// End-to-end: DaemonClient against Tests/fake_daemon.py over a real unix socket.
final class DaemonClientTests: XCTestCase {
    var process: Process?
    var socketPath = ""

    override func setUpWithError() throws {
        socketPath = "/tmp/pdr-test-\(getpid())-\(Int.random(in: 1000...9999)).sock"
        try startDaemon()
    }

    func startDaemon() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fake_daemon.py")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") || FileManager.default.fileExists(atPath: "/usr/bin/python3"),
              FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("python3 or fake_daemon.py not available")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "--socket", socketPath]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        process = p
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !isSocketReachable(socketPath) { usleep(100_000) }
        guard isSocketReachable(socketPath) else { throw XCTSkip("fake daemon didn't start") }
    }

    override func tearDown() {
        process?.terminate()
        process?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// One iterator per test: dropping an AsyncStream iterator terminates the stream.
    func waitForConnection(_ it: inout AsyncStream<DaemonEvent>.Iterator) async throws -> HelloResult {
        var failures = 0
        while let event = await it.next() {
            if case .connection(.connected(let h)) = event { return h }
            if case .connection(.disconnected) = event { failures += 1; if failures > 12 { break } }
        }
        throw ClientError.connectionClosed
    }

    func testHelloRequestsAndNotifications() async throws {
        let client = DaemonClient(socketPath: socketPath, clientVersion: "test")
        var it = client.events.makeAsyncIterator()
        await client.start()
        let hello = try await waitForConnection(&it)
        XCTAssertEqual(hello.protocol, 1)
        XCTAssertEqual(hello.rcloneVersion, "v1.75.0")

        let jobs = try await client.call("jobs.list", as: JobsResult.self).jobs
        XCTAssertGreaterThanOrEqual(jobs.count, 5)
        XCTAssertTrue(jobs.contains { $0.state == .running })
        let accounts = try await client.call("accounts.list", as: AccountsResult.self).accounts
        XCTAssertTrue(accounts.contains { $0.provider == "drive" })
        let actions = try await client.call("actions.list", ActionsListParams(includeResolved: false), as: ActionsResult.self).actions
        XCTAssertTrue(actions.allSatisfy { !$0.resolved })
        let providers = try await client.call("accounts.providers", as: ProvidersResult.self).providers
        XCTAssertTrue(providers.contains { $0.id == "s3" && !$0.fields.isEmpty })

        // RPC errors surface as RPCErrorPayload with the protocol code.
        do {
            _ = try await client.call("jobs.get", IDParams("missing"), as: JobResult.self)
            XCTFail("expected not found")
        } catch let e as RPCErrorPayload {
            XCTAssertEqual(e.code, RPCErrorPayload.notFound)
        }

        // Notifications: job.progress and overall.progress arrive at ~4 Hz.
        var gotJob = false, gotOverall = false
        let deadline = Date().addingTimeInterval(5)
        while let event = await it.next() {
            if case .jobProgress(let n) = event, n.progress.totalBytes > 0 { gotJob = true }
            if case .overall(let o) = event, o.running > 0 { gotOverall = true }
            if (gotJob && gotOverall) || Date() > deadline { break }
        }
        XCTAssertTrue(gotJob)
        XCTAssertTrue(gotOverall)

        try await client.send("system.state", SystemState(network: .init(ssid: "Home"), power: .init(onBattery: true, batteryPercent: 50)))
        await client.stop()
    }

    func testReconnectsAfterDaemonRestart() async throws {
        let client = DaemonClient(socketPath: socketPath, clientVersion: "test")
        var it = client.events.makeAsyncIterator()
        await client.start()
        _ = try await waitForConnection(&it)
        process?.terminate()
        process?.waitUntilExit()
        var sawDisconnect = false
        while let event = await it.next() {
            if case .connection(.disconnected) = event { sawDisconnect = true; break }
        }
        XCTAssertTrue(sawDisconnect)
        do {
            _ = try await client.call("jobs.list", as: JobsResult.self)
            XCTFail("calls fail fast while disconnected")
        } catch { }
        try startDaemon() // restart the fake daemon on the same socket
        _ = try await waitForConnection(&it)
        let jobs = try await client.call("jobs.list", as: JobsResult.self).jobs
        XCTAssertFalse(jobs.isEmpty)
        await client.stop()
    }
}
