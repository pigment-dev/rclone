import Foundation
import RCloneKit
import ServiceManagement

/// Finds or starts `pdrcloned`:
///  1. `PDRCLONE_SOCKET` / `PDRCLONE_HOME` → connect only (developer / fake daemon).
///  2. `--demo` → spawn the bundled daemon as `pdrcloned --demo --socket <tmp>` (screenshots).
///  3. Default socket; if unreachable register the bundled LaunchAgent with SMAppService,
///     and if that doesn't bring it up, spawn `Contents/MacOS/pdrcloned` as a child process.
final class DaemonLauncher: @unchecked Sendable {
    static let agentPlist = "com.pigmentdev.rclone.daemon.plist"
    static let agentLabel = "com.pigmentdev.rclone.daemon"

    let socketPath: String
    let demo: Bool
    let overridden: Bool
    private let lock = NSLock()
    private var child: Process?
    private var agentTried = false
    private(set) var lastNote: String = ""

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        demo = arguments.contains("--demo")
        if demo {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pdrclone-demo-\(getpid())")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            socketPath = (dir as NSString).appendingPathComponent("d.sock")
            overridden = true
        } else {
            let r = DaemonPaths.resolveSocket(environment: environment)
            socketPath = r.path
            overridden = r.overridden
        }
    }

    var bundledDaemon: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pdrcloned")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var bundledAgentPlist: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(Self.agentPlist)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var agentStatus: SMAppService.Status { SMAppService.agent(plistName: Self.agentPlist).status }

    var childRunning: Bool { lock.withLock { child?.isRunning ?? false } }

    /// Called by DaemonClient before every connection attempt.
    func ensureRunning(attempt: Int) async {
        if isSocketReachable(socketPath) { return }
        if demo { spawnChild(extra: ["--demo"]); await waitForSocket(seconds: 3); return }
        if overridden { return } // someone else owns that socket (fake daemon, dev build)
        if !agentTried, bundledAgentPlist != nil {
            agentTried = true
            do {
                let service = SMAppService.agent(plistName: Self.agentPlist)
                if service.status != .enabled { try service.register() }
                lastNote = "LaunchAgent registered"
            } catch {
                lastNote = "LaunchAgent: \(error.localizedDescription)"
            }
            if await waitForSocket(seconds: 3) { return }
        }
        if attempt >= 2 || bundledAgentPlist == nil {
            spawnChild(extra: [])
            await waitForSocket(seconds: 3)
        }
    }

    @discardableResult
    private func waitForSocket(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath), isSocketReachable(socketPath) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    private func spawnChild(extra: [String]) {
        lock.lock(); defer { lock.unlock() }
        if child?.isRunning == true { return }
        guard let exe = bundledDaemon else { lastNote = "pdrcloned isn't bundled"; return }
        let p = Process()
        p.executableURL = exe
        p.arguments = extra + ["--socket", socketPath]
        var env = ProcessInfo.processInfo.environment
        if demo { env["PDRCLONE_HOME"] = (socketPath as NSString).deletingLastPathComponent }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            child = p
            lastNote = "Started pdrcloned (pid \(p.processIdentifier))"
        } catch {
            lastNote = "Couldn't start pdrcloned: \(error.localizedDescription)"
        }
    }

    /// Restart the daemon however it was started.
    func restart() {
        let running = lock.withLock { child?.isRunning == true ? child : nil }
        if let running {
            running.terminate()
            lock.withLock { child = nil }
            return // ensureRunning respawns on reconnect
        }
        if agentStatus == .enabled {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.agentLabel)"]
            try? p.run()
        }
    }

    func unregisterAgent() {
        try? SMAppService.agent(plistName: Self.agentPlist).unregister()
    }

    /// The demo daemon dies with the app; a fallback child keeps syncing after the UI quits.
    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        if demo, let child, child.isRunning {
            child.terminate()
            try? FileManager.default.removeItem(atPath: (socketPath as NSString).deletingLastPathComponent)
        }
    }
}
