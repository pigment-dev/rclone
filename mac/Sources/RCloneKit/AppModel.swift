import Foundation
import Observation

/// What the menu bar icon should show. Pure value so it can be diffed and unit-tested.
public struct MenuIconState: Equatable, Sendable {
    public var offline = false
    public var running = false
    public var percent: Double? = nil
    public var speed: Double = 0
    public var paused = false
    public var attention = false
    public init(offline: Bool = false, running: Bool = false, percent: Double? = nil, speed: Double = 0, paused: Bool = false, attention: Bool = false) {
        self.offline = offline; self.running = running; self.percent = percent; self.speed = speed; self.paused = paused; self.attention = attention
    }

    public enum TextMode: String, CaseIterable, Sendable { case none, percent, speed }

    /// Optional text next to the icon, only while syncing.
    public func text(_ mode: TextMode) -> String? {
        guard running, !offline else { return nil }
        switch mode {
        case .none: return nil
        case .percent: return percent.map { Fmt.percent($0) }
        case .speed: return speed > 0 ? Fmt.speed(speed) : nil
        }
    }

    /// Percent quantised to whole numbers so the icon is redrawn at most once per visible change.
    public var quantised: MenuIconState {
        var s = self
        s.percent = percent.map { ($0).rounded(.down) }
        s.speed = (speed / 10_000).rounded() * 10_000
        return s
    }

    public var accessibilityLabel: String {
        if offline { return L("PigmentDev rClone — sync service offline") }
        if paused { return L("PigmentDev rClone — paused") }
        if running { return L("PigmentDev rClone — syncing") + (percent.map { " " + Fmt.percent($0) } ?? "") }
        if attention { return L("PigmentDev rClone — needs attention") }
        return L("PigmentDev rClone — up to date")
    }
}

public enum PauseDuration: Hashable, Sendable {
    case oneHour, untilTomorrow, untilResumed

    /// Seconds from `now` (the daemon's `untilSec` is interpreted as a duration), nil = until resumed.
    public func seconds(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        switch self {
        case .oneHour: return 3600
        case .untilTomorrow:
            let start = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
            let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)!
            return max(60, Int(morning.timeIntervalSince(now)))
        case .untilResumed: return nil
        }
    }
}

/// App-wide state, fed by `DaemonClient` events. All mutation on the main actor.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connection: ConnectionState = .idle
    public private(set) var hello: HelloResult?
    public var jobs: [Job] = []
    public var accounts: [Account] = []
    public var providers: [Provider] = []
    public var actions: [Action] = []
    public var settings: DaemonSettings?
    public var overall = OverallProgress()
    public var health: HealthNote?
    public var lastError: String?
    public var pausedUntil: Date?
    public var pausedIndefinitely = false
    /// Live tail buffer (newest last), only filled while subscribed to log.line.
    public var liveLog: [LogLine] = []
    /// Overall speed samples (bytes/s), one per second while running; for the Dashboard chart.
    public var speedHistory: [SpeedSample] = []
    public var loaded = false

    @ObservationIgnored public private(set) var client: DaemonClient?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var lastSpeedSample = Date.distantPast
    /// Hook for side effects in the app target (user notifications, icon updates).
    @ObservationIgnored public var onEvent: ((DaemonEvent) -> Void)?
    @ObservationIgnored public var onPreview: ((PreviewNote) -> Void)?

    public struct SpeedSample: Identifiable, Equatable, Sendable {
        public var id: Date { time }
        public var time: Date
        public var speed: Double
    }

    public init() {}

    public func attach(_ client: DaemonClient) {
        self.client = client
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    // MARK: Derived

    public var isConnected: Bool { connection.isConnected }
    public var unresolvedActions: [Action] { actions.filter { !$0.resolved } }
    public var attentionCount: Int { unresolvedActions.filter(\.needsAttention).count }
    public var runningJobs: [Job] { jobs.filter { $0.state == .running } }
    public var allPaused: Bool { pausedIndefinitely || (pausedUntil.map { $0 > Date() } ?? false) || (!jobs.isEmpty && jobs.filter(\.enabled).allSatisfy { $0.state == .paused }) }

    public var menuIconState: MenuIconState {
        let running = overall.running > 0 || !runningJobs.isEmpty
        var percent: Double? = nil
        if running {
            if overall.percent > 0 || overall.totalBytes > 0 { percent = overall.percent }
            else if let p = runningJobs.first?.progress { percent = p.percent }
        }
        return MenuIconState(offline: !isConnected && loaded, running: running && isConnected, percent: percent,
                             speed: overall.speed, paused: allPaused && !running, attention: attentionCount > 0)
    }

    public func job(_ id: String?) -> Job? { id.flatMap { id in jobs.first { $0.id == id } } }
    public func account(_ id: String?) -> Account? { id.flatMap { id in accounts.first { $0.id == id } } }
    public func provider(_ id: String?) -> Provider? { id.flatMap { id in providers.first { $0.id == id } } }

    // MARK: Event application

    public func apply(_ event: DaemonEvent) {
        switch event {
        case .connection(let state):
            connection = state
            if case .connected(let h) = state {
                hello = h
                lastError = nil
                Task { await refreshAll() }
            } else if case .disconnected = state {
                loaded = true
                overall = OverallProgress()
            }
        case .jobState(let note):
            if let i = jobs.firstIndex(where: { $0.id == note.jobId }) {
                var status = note.status
                if status.state == .running, status.progress == nil { status.progress = jobs[i].status?.progress }
                if status.state != .running { status.progress = nil }
                jobs[i].status = status
            } else {
                Task { await refreshJobs() }
            }
        case .jobProgress(let note):
            if let i = jobs.firstIndex(where: { $0.id == note.jobId }) {
                var status = jobs[i].status ?? JobStatus()
                status.progress = note.progress
                if status.state != .running { status.state = .running }
                jobs[i].status = status
            }
        case .overall(let o):
            overall = o
            let now = Date()
            if now.timeIntervalSince(lastSpeedSample) >= 1 {
                lastSpeedSample = now
                speedHistory.append(.init(time: now, speed: o.speed))
                if speedHistory.count > 300 { speedHistory.removeFirst(speedHistory.count - 300) }
            }
        case .actionNew(let a), .actionUpdated(let a):
            if let i = actions.firstIndex(where: { $0.id == a.id }) { actions[i] = a } else { actions.insert(a, at: 0) }
        case .logLine(let line):
            liveLog.append(line)
            if liveLog.count > 2000 { liveLog.removeFirst(liveLog.count - 2000) }
        case .health(let h):
            health = h
        case .preview(let p):
            onPreview?(p)
        case .other:
            break
        }
        onEvent?(event)
    }

    // MARK: Refresh

    public func refreshAll() async {
        async let j: Void = refreshJobs()
        async let a: Void = refreshAccounts()
        async let x: Void = refreshActions()
        async let p: Void = refreshProviders()
        async let s: Void = refreshSettings()
        _ = await (j, a, x, p, s)
        loaded = true
    }

    public func refreshJobs() async {
        guard let client else { return }
        do { jobs = try await client.call("jobs.list", as: JobsResult.self).jobs } catch { report(error) }
    }

    public func refreshAccounts() async {
        guard let client else { return }
        do { accounts = try await client.call("accounts.list", as: AccountsResult.self).accounts } catch { report(error) }
    }

    public func refreshActions() async {
        guard let client else { return }
        do { actions = try await client.call("actions.list", ActionsListParams(includeResolved: true), as: ActionsResult.self).actions } catch { report(error) }
    }

    public func refreshProviders() async {
        guard let client else { return }
        do { providers = try await client.call("accounts.providers", as: ProvidersResult.self).providers } catch { report(error, quiet: true) }
    }

    public func refreshSettings() async {
        guard let client else { return }
        do { settings = try await client.call("settings.get", as: SettingsResult.self).settings } catch { report(error, quiet: true) }
    }

    public func report(_ error: Error, quiet: Bool = false) {
        if case ClientError.notConnected = error { return }
        if !quiet { lastError = error.localizedDescription }
    }

    // MARK: Commands

    @discardableResult
    public func perform(_ work: (DaemonClient) async throws -> Void) async -> Bool {
        guard let client else { lastError = ClientError.notConnected.localizedDescription; return false }
        do { try await work(client); return true } catch { report(error); return false }
    }

    public func run(_ id: String, dryRun: Bool = false, resync: Bool = false) async {
        await perform { try await $0.send("jobs.run", RunJobParams(id: id, dryRun: dryRun, resync: resync)) }
    }
    public func pause(_ id: String) async { await perform { try await $0.send("jobs.pause", IDParams(id)) } }
    public func resume(_ id: String) async { await perform { try await $0.send("jobs.resume", IDParams(id)) } }
    public func cancel(_ id: String) async { await perform { try await $0.send("jobs.cancel", IDParams(id)) } }

    public func pauseAll(_ duration: PauseDuration) async {
        let secs = duration.seconds()
        if await perform({ try await $0.send("jobs.pauseAll", PauseAllParams(untilSec: secs)) }) {
            pausedIndefinitely = secs == nil
            pausedUntil = secs.map { Date().addingTimeInterval(TimeInterval($0)) }
            await refreshJobs()
        }
    }

    public func resumeAll() async {
        if await perform({ try await $0.send("jobs.resumeAll") }) {
            pausedIndefinitely = false
            pausedUntil = nil
            await refreshJobs()
        }
    }

    public func deleteJob(_ id: String) async {
        if await perform({ try await $0.send("jobs.delete", IDParams(id)) }) { jobs.removeAll { $0.id == id } }
    }

    public func createJob(_ job: Job) async throws -> Job {
        guard let client else { throw ClientError.notConnected }
        let created = try await client.call("jobs.create", CreateJobParams(job: JobSpec(job)), as: JobResult.self).job
        if let i = jobs.firstIndex(where: { $0.id == created.id }) { jobs[i] = created } else { jobs.append(created) }
        return created
    }

    public func updateJob(_ job: Job) async throws -> Job {
        guard let client else { throw ClientError.notConnected }
        let updated = try await client.call("jobs.update", UpdateJobParams(id: job.id, patch: JobSpec(job)), as: JobResult.self).job
        if let i = jobs.firstIndex(where: { $0.id == updated.id }) { jobs[i] = updated }
        return updated
    }

    public func resolve(_ action: Action, choice: String) async {
        guard let client else { return }
        do {
            let updated = try await client.call("actions.resolve", ResolveParams(id: action.id, choice: choice), as: ActionResult.self).action
            if let i = actions.firstIndex(where: { $0.id == updated.id }) { actions[i] = updated }
        } catch {
            report(error)
        }
    }

    public func dismissAll() async {
        if await perform({ try await $0.send("actions.dismissAll") }) { await refreshActions() }
    }

    public func setLiveTail(_ on: Bool) async {
        guard let client else { return }
        if on {
            try? await client.updateSubscriptions(Topic.defaults + [Topic.logLine])
        } else {
            liveLog.removeAll()
            do { try await client.send("unsubscribe", SubscribeParams(topics: [Topic.logLine])) }
            catch { try? await client.updateSubscriptions(Topic.defaults) }
            await client.setTopics(Topic.defaults)
        }
    }

    public func saveSettings(_ s: DaemonSettings) async {
        guard let client else { return }
        do { settings = try await client.call("settings.set", SettingsPatchParams(patch: s), as: SettingsResult.self).settings }
        catch { report(error) }
    }
}
