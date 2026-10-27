import Foundation

// Typed models for every type in docs/PROTOCOL.md (v1).
// Decoding is lenient (missing keys → defaults, unknown enum strings → fallback);
// nullable fields encode as explicit `null` so patches can clear them.

// MARK: - Session

public struct HelloParams: Codable, Sendable {
    public var client: String
    public var version: String
    public init(client: String = "mac", version: String) { self.client = client; self.version = version }
}

public struct HelloResult: Codable, Equatable, Sendable {
    @Default<EmptyString> public var daemonVersion: String = ""
    @Default<EmptyString> public var rcloneVersion: String = ""
    @Default<ZeroInt> public var `protocol`: Int = 0
    @Default<EmptyString> public var os: String = ""
    @Default<EmptyString> public var arch: String = ""
    @Default<EmptyString> public var dataDir: String = ""
    @Default<ZeroInt> public var pid: Int = 0
    @Default<EmptyString> public var startedAt: String = ""
    @Default<False> public var demo: Bool = false
    public init() {}
}

public struct DaemonInfo: Codable, Equatable, Sendable {
    @Default<EmptyString> public var daemonVersion: String = ""
    @Default<EmptyString> public var rcloneVersion: String = ""
    @Default<ZeroInt> public var `protocol`: Int = 0
    @Default<EmptyString> public var os: String = ""
    @Default<EmptyString> public var arch: String = ""
    @Default<EmptyString> public var dataDir: String = ""
    @Default<ZeroInt> public var pid: Int = 0
    @Default<EmptyString> public var startedAt: String = ""
    @Default<ZeroInt> public var jobsRunning: Int = 0
    @Default<Zero> public var uptimeSec: Int64 = 0
    @Default<Zero> public var rssBytes: Int64 = 0
    @Default<ZeroInt> public var goroutines: Int = 0
    @Default<False> public var demo: Bool = false
    public init() {}
}

public struct SubscribeParams: Codable, Sendable {
    public var topics: [String]
    public init(topics: [String]) { self.topics = topics }
}

public enum Topic {
    public static let jobState = "job.state"
    public static let jobProgress = "job.progress"
    public static let actionNew = "action.new"
    public static let actionUpdated = "action.updated"
    public static let logLine = "log.line"
    public static let daemonHealth = "daemon.health"
    public static let transfer = "transfer"
    /// Daemon default after hello: everything except log.line and transfer.
    public static let defaults = [jobState, jobProgress, actionNew, actionUpdated, daemonHealth]
}

public struct OKResult: Codable, Equatable, Sendable {
    @Default<True> public var ok: Bool = true
    public init() {}
}

// MARK: - System state

public struct SystemState: Codable, Equatable, Sendable {
    public struct Network: Codable, Equatable, Sendable {
        public enum Status: String, LenientEnum { case satisfied, unsatisfied; public static var fallback: Status { .unsatisfied } }
        public enum Interface: String, LenientEnum { case wifi, ethernet, cellular, other, none; public static var fallback: Interface { .other } }
        public var status: Status
        public var interface: Interface
        public var expensive: Bool
        public var constrained: Bool
        @Nullable public var ssid: String?
        public var vpn: Bool
        public init(status: Status = .satisfied, interface: Interface = .wifi, expensive: Bool = false, constrained: Bool = false, ssid: String? = nil, vpn: Bool = false) {
            self.status = status; self.interface = interface; self.expensive = expensive
            self.constrained = constrained; self.ssid = ssid; self.vpn = vpn
        }
    }
    public struct Power: Codable, Equatable, Sendable {
        public var onBattery: Bool
        @Nullable public var batteryPercent: Int?
        public var lowPowerMode: Bool
        public init(onBattery: Bool = false, batteryPercent: Int? = nil, lowPowerMode: Bool = false) {
            self.onBattery = onBattery; self.batteryPercent = batteryPercent; self.lowPowerMode = lowPowerMode
        }
    }
    public struct Disk: Codable, Equatable, Sendable {
        public var freeBytes: Int64
        public init(freeBytes: Int64 = 0) { self.freeBytes = freeBytes }
    }
    public var network: Network
    public var power: Power
    public var disk: Disk
    public var sleeping: Bool
    public init(network: Network = .init(), power: Power = .init(), disk: Disk = .init(), sleeping: Bool = false) {
        self.network = network; self.power = power; self.disk = disk; self.sleeping = sleeping
    }
}

// MARK: - Accounts

public struct FieldOption: Codable, Equatable, Hashable, Sendable {
    @Default<EmptyString> public var value: String = ""
    @Default<EmptyString> public var label: String = ""
    public init(value: String, label: String) { self.value = value; self.label = label }

    public init(from decoder: Decoder) throws {
        // Accept both {value,label} and bare strings.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            value = s; label = s; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        value = v?.stringValue ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? value
    }
    enum CodingKeys: String, CodingKey { case value, label }
}

public struct Field: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, LenientEnum { case string, password, bool, int, select; public static var fallback: Kind { .string } }
    public var id: String { name }
    @Default<EmptyString> public var name: String = ""
    @Default<EmptyString> public var label: String = ""
    @Default<EmptyString> public var help: String = ""
    @Default<FallbackCase<Kind>> public var type: Kind = .string
    @Default<False> public var required: Bool = false
    public var `default`: JSONValue?
    @Default<EmptyList<FieldOption>> public var options: [FieldOption] = []
    @Default<False> public var advanced: Bool = false
    /// Optional rclone provider filter (e.g. S3 fields that apply only to "AWS").
    public var provider: String?
    public init(name: String, label: String, help: String = "", type: Kind = .string, required: Bool = false, default: JSONValue? = nil, options: [FieldOption] = [], advanced: Bool = false) {
        self.name = name; self.label = label; self.help = help; self.type = type
        self.required = required; self.default = `default`; self.options = options; self.advanced = advanced
    }
}

public struct Provider: Codable, Equatable, Identifiable, Sendable {
    public enum Auth: String, LenientEnum { case oauth, fields; public static var fallback: Auth { .fields } }
    public enum Category: String, LenientEnum { case cloud, object, server, local; public static var fallback: Category { .cloud } }
    @Default<EmptyString> public var id: String = ""
    @Default<EmptyString> public var name: String = ""
    @Default<FallbackCase<Auth>> public var auth: Auth = .fields
    @Default<FallbackCase<Category>> public var category: Category = .cloud
    @Default<False> public var popular: Bool = false
    @Default<EmptyList<Field>> public var fields: [Field] = []
    public init(id: String, name: String, auth: Auth, category: Category, popular: Bool = false, fields: [Field] = []) {
        self.id = id; self.name = name; self.auth = auth; self.category = category; self.popular = popular; self.fields = fields
    }
}

public struct ProvidersResult: Codable, Sendable { @Default<EmptyList<Provider>> public var providers: [Provider] = [] }

public struct Quota: Codable, Equatable, Sendable {
    public var total: Int64?
    public var used: Int64?
    public var free: Int64?
    public var trashed: Int64?
    public init(total: Int64? = nil, used: Int64? = nil, free: Int64? = nil, trashed: Int64? = nil) {
        self.total = total; self.used = used; self.free = free; self.trashed = trashed
    }
    /// 0…1 used fraction when known.
    public var usedFraction: Double? {
        guard let total, total > 0, let used else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, LenientEnum { case ok, needsAuth, error, unknown; public static var fallback: Status { .unknown } }
    @Default<EmptyString> public var id: String = ""
    @Default<EmptyString> public var provider: String = ""
    @Default<EmptyString> public var name: String = ""
    @Default<EmptyString> public var remote: String = ""
    @Default<FallbackCase<Status>> public var status: Status = .unknown
    public var error: String?
    @Default<EmptyString> public var createdAt: String = ""
    public var quota: Quota?
    /// Who the account is signed in as, when the provider reports it.
    public var user: AccountUser?
    /// "name · email", or whichever is known.
    public var userLine: String? {
        guard let u = user else { return nil }
        let parts = [u.name, u.email].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    public init(id: String, provider: String, name: String, remote: String = "", status: Status = .ok, error: String? = nil, createdAt: String = "", quota: Quota? = nil) {
        self.id = id; self.provider = provider; self.name = name; self.remote = remote
        self.status = status; self.error = error; self.createdAt = createdAt; self.quota = quota
    }
}

public struct AccountsResult: Codable, Sendable { @Default<EmptyList<Account>> public var accounts: [Account] = [] }

public struct AddAccountStartParams: Codable, Sendable {
    public var provider: String
    public var name: String
    public var fields: [String: JSONValue]
    public init(provider: String, name: String, fields: [String: JSONValue]) { self.provider = provider; self.name = name; self.fields = fields }
}

public struct AddAccountContinueParams: Codable, Sendable {
    public var sessionId: String
    public var answer: JSONValue
    public init(sessionId: String, answer: JSONValue = .null) { self.sessionId = sessionId; self.answer = answer }
}

public struct AddAccountQuestion: Codable, Equatable, Sendable {
    @Default<EmptyString> public var name: String = ""
    @Default<EmptyString> public var label: String = ""
    @Default<EmptyString> public var help: String = ""
    @Default<FallbackCase<Field.Kind>> public var type: Field.Kind = .string
    @Default<EmptyList<FieldOption>> public var options: [FieldOption] = []
    public var `default`: JSONValue?
    public init() {}
    public var asField: Field { Field(name: name, label: label, help: help, type: type, required: false, default: `default`, options: options) }
}

public struct AddAccountResult: Codable, Equatable, Sendable {
    public enum State: String, LenientEnum { case done, needsOAuth, needsInput, error; public static var fallback: State { .error } }
    @Default<FallbackCase<State>> public var state: State = .error
    public var account: Account?
    public var sessionId: String?
    public var authUrl: String?
    public var question: AddAccountQuestion?
    public var error: String?
    public init() {}
}

public struct IDParams: Codable, Sendable { public var id: String; public init(_ id: String) { self.id = id } }
public struct SessionParams: Codable, Sendable { public var sessionId: String; public init(_ id: String) { sessionId = id } }
public struct RenameParams: Codable, Sendable { public var id: String; public var name: String; public init(id: String, name: String) { self.id = id; self.name = name } }
public struct RemoveAccountParams: Codable, Sendable { public var id: String; public var force: Bool; public init(id: String, force: Bool) { self.id = id; self.force = force } }

public struct AccountTestResult: Codable, Equatable, Sendable {
    @Default<False> public var ok: Bool = false
    public var error: String?
    public var latencyMs: Int?
    public init() {}
}

public struct QuotaResult: Codable, Sendable { public var quota: Quota? }
public struct AccountUser: Codable, Equatable, Sendable {
    @Default<EmptyString> public var name: String = ""
    @Default<EmptyString> public var email: String = ""
    public init(name: String = "", email: String = "") { self.name = name; self.email = email }
}
public struct AccountResult: Codable, Sendable { public var account: Account? }
public struct URLResult: Codable, Sendable { @Default<EmptyString> public var url: String = "" }

// MARK: - Remote browsing

public struct RemoteListParams: Codable, Sendable {
    @Nullable public var accountId: String?
    public var path: String
    public var dirsOnly: Bool
    public init(accountId: String?, path: String, dirsOnly: Bool = true) { self.accountId = accountId; self.path = path; self.dirsOnly = dirsOnly }
}

public struct RemoteEntry: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    @Default<EmptyString> public var name: String = ""
    @Default<EmptyString> public var path: String = ""
    @Default<False> public var isDir: Bool = false
    @Default<Zero> public var size: Int64 = 0
    @Default<EmptyString> public var modTime: String = ""
    public init(name: String, path: String, isDir: Bool, size: Int64 = 0, modTime: String = "") {
        self.name = name; self.path = path; self.isDir = isDir; self.size = size; self.modTime = modTime
    }
}

public struct RemoteListResult: Codable, Sendable {
    @Default<EmptyString> public var path: String = ""
    @Default<EmptyList<RemoteEntry>> public var entries: [RemoteEntry] = []
}

public struct MkdirParams: Codable, Sendable {
    @Nullable public var accountId: String?
    public var path: String
    public init(accountId: String?, path: String) { self.accountId = accountId; self.path = path }
}

// MARK: - Jobs

public enum SyncDirection: String, LenientEnum { case upload, download, twoWay; public static var fallback: SyncDirection { .upload } }
public enum DeletePolicy: String, LenientEnum { case mirror, archive, never; public static var fallback: DeletePolicy { .never } }
public enum ConflictPolicy: String, LenientEnum { case newer, keepBoth, preferLocal, preferRemote, ask; public static var fallback: ConflictPolicy { .keepBoth } }

public struct FilterRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, LenientEnum { case exclude, include; public static var fallback: Kind { .exclude } }
    public var id: String { kind.rawValue + ":" + pattern }
    @Default<FallbackCase<Kind>> public var kind: Kind = .exclude
    @Default<EmptyString> public var pattern: String = ""
    public init(kind: Kind, pattern: String) { self.kind = kind; self.pattern = pattern }
}

public struct Filters: Codable, Equatable, Sendable {
    @Default<EmptyList<String>> public var presets: [String] = []
    @Default<EmptyList<FilterRule>> public var rules: [FilterRule] = []
    @Nullable public var maxSizeMB: Int?
    @Default<Zero> public var minAgeSec: Int64 = 0
    @Default<EmptyList<String>> public var excludeIfPresent: [String] = []
    @Default<False> public var respectGitignore: Bool = false
    @Default<False> public var skipSymlinks: Bool = false
    public init(presets: [String] = FilterPreset.recommended, rules: [FilterRule] = [], maxSizeMB: Int? = nil, minAgeSec: Int64 = 0,
                excludeIfPresent: [String] = [".nosync"], respectGitignore: Bool = false, skipSymlinks: Bool = false) {
        self.presets = presets; self.rules = rules; self.maxSizeMB = maxSizeMB; self.minAgeSec = minAgeSec
        self.excludeIfPresent = excludeIfPresent; self.respectGitignore = respectGitignore; self.skipSymlinks = skipSymlinks
    }
}

public struct WeeklyTrigger: Codable, Equatable, Sendable {
    public var day: Int
    public var time: String
    public init(day: Int, time: String) { self.day = day; self.time = time }
}

public struct Triggers: Codable, Equatable, Sendable {
    @Default<False> public var onChange: Bool = false
    @Default<Ten> public var debounceSec: Int = 10
    @Nullable public var intervalMin: Int?
    @Nullable public var daily: String?
    @Nullable public var weekly: WeeklyTrigger?
    @Nullable public var cron: String?
    @Default<False> public var onWake: Bool = false
    @Default<True> public var manual: Bool = true
    public init(onChange: Bool = true, debounceSec: Int = 10, intervalMin: Int? = nil, daily: String? = nil, weekly: WeeklyTrigger? = nil, cron: String? = nil, onWake: Bool = false, manual: Bool = true) {
        self.onChange = onChange; self.debounceSec = debounceSec; self.intervalMin = intervalMin; self.daily = daily
        self.weekly = weekly; self.cron = cron; self.onWake = onWake; self.manual = manual
    }
}

public struct JobNetwork: Codable, Equatable, Sendable {
    @Default<False> public var allowCellular: Bool = false
    @Default<False> public var allowExpensive: Bool = false
    @Default<False> public var wifiOnly: Bool = false
    @Default<EmptyList<String>> public var ssidAllow: [String] = []
    @Default<EmptyList<String>> public var ssidDeny: [String] = []
    @Default<False> public var pauseOnBattery: Bool = false
    @Nullable public var minBatteryPercent: Int?
    public init(allowCellular: Bool = false, allowExpensive: Bool = false, wifiOnly: Bool = false, ssidAllow: [String] = [], ssidDeny: [String] = [], pauseOnBattery: Bool = false, minBatteryPercent: Int? = nil) {
        self.allowCellular = allowCellular; self.allowExpensive = allowExpensive; self.wifiOnly = wifiOnly
        self.ssidAllow = ssidAllow; self.ssidDeny = ssidDeny; self.pauseOnBattery = pauseOnBattery; self.minBatteryPercent = minBatteryPercent
    }
}

public struct Limits: Codable, Equatable, Sendable {
    @Nullable public var bwUpKBps: Int?
    @Nullable public var bwDownKBps: Int?
    @Default<Four> public var transfers: Int = 4
    @Default<Eight> public var checkers: Int = 8
    public init(bwUpKBps: Int? = nil, bwDownKBps: Int? = nil, transfers: Int = 4, checkers: Int = 8) {
        self.bwUpKBps = bwUpKBps; self.bwDownKBps = bwDownKBps; self.transfers = transfers; self.checkers = checkers
    }
}

public struct Safety: Codable, Equatable, Sendable {
    @Default<TwentyFive> public var maxDeletePercent: Int = 25
    @Default<True> public var dryRunFirst: Bool = true
    @Default<False> public var checksum: Bool = false
    public init(maxDeletePercent: Int = 25, dryRunFirst: Bool = true, checksum: Bool = false) {
        self.maxDeletePercent = maxDeletePercent; self.dryRunFirst = dryRunFirst; self.checksum = checksum
    }
}

public struct Transfer: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    @Default<EmptyString> public var name: String = ""
    @Default<Zero> public var size: Int64 = 0
    @Default<Zero> public var bytes: Int64 = 0
    @Default<ZeroDouble> public var percent: Double = 0
    @Default<ZeroDouble> public var speed: Double = 0
    public init(name: String, size: Int64, bytes: Int64, percent: Double, speed: Double) {
        self.name = name; self.size = size; self.bytes = bytes; self.percent = percent; self.speed = speed
    }
}

public struct SyncProgress: Codable, Equatable, Sendable {
    @Default<Zero> public var bytes: Int64 = 0
    @Default<Zero> public var totalBytes: Int64 = 0
    @Default<Zero> public var files: Int64 = 0
    @Default<Zero> public var totalFiles: Int64 = 0
    @Default<ZeroDouble> public var speed: Double = 0
    public var eta: Double?
    @Default<ZeroDouble> public var percent: Double = 0
    @Default<Zero> public var checks: Int64 = 0
    @Default<Zero> public var totalChecks: Int64 = 0
    @Default<Zero> public var errors: Int64 = 0
    @Default<EmptyList<Transfer>> public var transferring: [Transfer] = []
    /// Large jobs run one top-level folder at a time: which part is running.
    @Default<EmptyString> public var phase: String = ""
    @Default<ZeroInt> public var step: Int = 0
    @Default<ZeroInt> public var steps: Int = 0
    /// "Folder 3 of 42 · hesabyar", or nil for a single-part run.
    public var partLine: String? {
        guard steps > 1, step > 0 else { return nil }
        return step == 1 ? L("Part %d of %d · files at the top level", step, steps) : L("Folder %d of %d · %@", step - 1, steps - 1, phase)
    }
    /// Nothing counted yet: rclone is still listing both sides.
    public var isComparing: Bool { totalBytes == 0 && files == 0 && checks == 0 }
    public init(bytes: Int64 = 0, totalBytes: Int64 = 0, files: Int64 = 0, totalFiles: Int64 = 0, speed: Double = 0, eta: Double? = nil,
                percent: Double = 0, checks: Int64 = 0, totalChecks: Int64 = 0, errors: Int64 = 0, transferring: [Transfer] = []) {
        self.bytes = bytes; self.totalBytes = totalBytes; self.files = files; self.totalFiles = totalFiles; self.speed = speed
        self.eta = eta; self.percent = percent; self.checks = checks; self.totalChecks = totalChecks; self.errors = errors
        self.transferring = transferring
    }
    /// 0…1 fraction, preferring the daemon's percent and falling back to bytes.
    public var fraction: Double {
        if percent > 0 { return min(1, percent / 100) }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(totalBytes))
    }
    public var currentFile: String? { transferring.first?.name }
}

public struct RunSummary: Codable, Equatable, Identifiable, Sendable {
    @Default<EmptyString> public var id: String = ""
    @Default<EmptyString> public var startedAt: String = ""
    public var endedAt: String?
    @Default<False> public var ok: Bool = false
    public var error: String?
    @Default<Zero> public var bytes: Int64 = 0
    @Default<Zero> public var files: Int64 = 0
    @Default<Zero> public var deletes: Int64 = 0
    @Default<Zero> public var conflicts: Int64 = 0
    @Default<False> public var dryRun: Bool = false
    public init(id: String, startedAt: String, endedAt: String? = nil, ok: Bool, error: String? = nil, bytes: Int64 = 0, files: Int64 = 0, deletes: Int64 = 0, conflicts: Int64 = 0, dryRun: Bool = false) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.ok = ok; self.error = error
        self.bytes = bytes; self.files = files; self.deletes = deletes; self.conflicts = conflicts; self.dryRun = dryRun
    }
}

public struct JobStatus: Codable, Equatable, Sendable {
    public enum State: String, LenientEnum {
        case idle, queued, running, paused, waiting, error, needsBaseline
        public static var fallback: State { .idle }
    }
    @Default<FallbackCase<State>> public var state: State = .idle
    public var reason: String?
    public var lastRun: RunSummary?
    public var nextRun: String?
    public var progress: SyncProgress?
    public init(state: State = .idle, reason: String? = nil, lastRun: RunSummary? = nil, nextRun: String? = nil, progress: SyncProgress? = nil) {
        self.state = state; self.reason = reason; self.lastRun = lastRun; self.nextRun = nextRun; self.progress = progress
    }
}

public struct Job: Codable, Equatable, Identifiable, Sendable {
    @Default<EmptyString> public var id: String = ""
    @Default<EmptyString> public var name: String = ""
    @Default<True> public var enabled: Bool = true
    @Default<EmptyString> public var localPath: String = ""
    @Default<EmptyString> public var accountId: String = ""
    @Default<EmptyString> public var remotePath: String = ""
    @Default<FallbackCase<SyncDirection>> public var direction: SyncDirection = .upload
    @Default<FallbackCase<DeletePolicy>> public var deletePolicy: DeletePolicy = .archive
    @Default<Thirty> public var archiveRetentionDays: Int = 30
    @Default<FallbackCase<ConflictPolicy>> public var conflictPolicy: ConflictPolicy = .keepBoth
    public var filters: Filters = Filters()
    public var triggers: Triggers = Triggers()
    public var network: JobNetwork = JobNetwork()
    public var limits: Limits = Limits()
    public var safety: Safety = Safety()
    public var createdAt: String?
    public var updatedAt: String?
    public var status: JobStatus?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(Default<EmptyString>.self, forKey: .id)
        _name = try c.decode(Default<EmptyString>.self, forKey: .name)
        _enabled = try c.decode(Default<True>.self, forKey: .enabled)
        _localPath = try c.decode(Default<EmptyString>.self, forKey: .localPath)
        _accountId = try c.decode(Default<EmptyString>.self, forKey: .accountId)
        _remotePath = try c.decode(Default<EmptyString>.self, forKey: .remotePath)
        _direction = try c.decode(Default<FallbackCase<SyncDirection>>.self, forKey: .direction)
        _deletePolicy = try c.decode(Default<FallbackCase<DeletePolicy>>.self, forKey: .deletePolicy)
        _archiveRetentionDays = try c.decode(Default<Thirty>.self, forKey: .archiveRetentionDays)
        _conflictPolicy = try c.decode(Default<FallbackCase<ConflictPolicy>>.self, forKey: .conflictPolicy)
        filters = try c.decodeIfPresent(Filters.self, forKey: .filters) ?? Filters(presets: [], excludeIfPresent: [])
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers(onChange: false)
        network = try c.decodeIfPresent(JobNetwork.self, forKey: .network) ?? JobNetwork()
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
        safety = try c.decodeIfPresent(Safety.self, forKey: .safety) ?? Safety()
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        status = try c.decodeIfPresent(JobStatus.self, forKey: .status)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, localPath, accountId, remotePath, direction, deletePolicy, archiveRetentionDays,
             conflictPolicy, filters, triggers, network, limits, safety, createdAt, updatedAt, status
    }

    public var state: JobStatus.State { status?.state ?? .idle }
    public var progress: SyncProgress? { status?.progress }
}

/// The body of `jobs.create {job:…}` — a Job without id/status/timestamps.
public struct JobSpec: Codable, Equatable, Sendable {
    public var name: String
    public var enabled: Bool
    public var localPath: String
    public var accountId: String
    public var remotePath: String
    public var direction: SyncDirection
    public var deletePolicy: DeletePolicy
    public var archiveRetentionDays: Int
    public var conflictPolicy: ConflictPolicy
    public var filters: Filters
    public var triggers: Triggers
    public var network: JobNetwork
    public var limits: Limits
    public var safety: Safety

    public init(_ job: Job) {
        name = job.name; enabled = job.enabled; localPath = job.localPath; accountId = job.accountId
        remotePath = job.remotePath; direction = job.direction; deletePolicy = job.deletePolicy
        archiveRetentionDays = job.archiveRetentionDays; conflictPolicy = job.conflictPolicy
        filters = job.filters; triggers = job.triggers; network = job.network; limits = job.limits; safety = job.safety
    }

    /// Lenient: decodes through `Job` so missing keys get defaults and extra keys (id, status) are ignored.
    public init(from decoder: Decoder) throws { self.init(try Job(from: decoder)) }
}

public struct JobsResult: Codable, Sendable { @Default<EmptyList<Job>> public var jobs: [Job] = [] }
public struct JobResult: Codable, Sendable { public var job: Job }
public struct CreateJobParams: Codable, Sendable { public var job: JobSpec; public init(job: JobSpec) { self.job = job } }
public struct UpdateJobParams: Codable, Sendable { public var id: String; public var patch: JobSpec; public init(id: String, patch: JobSpec) { self.id = id; self.patch = patch } }

public struct RunJobParams: Codable, Sendable {
    public var id: String
    public var dryRun: Bool
    public var resync: Bool
    public init(id: String, dryRun: Bool = false, resync: Bool = false) { self.id = id; self.dryRun = dryRun; self.resync = resync }
}

public struct RunJobResult: Codable, Sendable { @Default<EmptyString> public var runId: String = "" }

public struct PauseAllParams: Codable, Sendable {
    @Nullable public var untilSec: Int?
    public init(untilSec: Int?) { self.untilSec = untilSec }
}

public enum PreviewParams: Encodable, Sendable {
    case id(String)
    case job(JobSpec)
    enum CodingKeys: String, CodingKey { case id, job }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let id): try c.encode(id, forKey: .id)
        case .job(let spec): try c.encode(spec, forKey: .job)
        }
    }
}

public struct ExcludedSample: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    @Default<EmptyString> public var path: String = ""
    @Default<EmptyString> public var rule: String = ""
    public init(path: String, rule: String) { self.path = path; self.rule = rule }
}

public struct PreviewSample: Codable, Equatable, Sendable {
    @Default<EmptyList<String>> public var adds: [String] = []
    @Default<EmptyList<String>> public var updates: [String] = []
    @Default<EmptyList<String>> public var deletes: [String] = []
    @Default<EmptyList<ExcludedSample>> public var excluded: [ExcludedSample] = []
    public init() {}
}

public struct PreviewResult: Codable, Equatable, Sendable {
    /// Present when the daemon answers asynchronously (result follows as `job.preview`).
    public var runId: String?
    @Default<Zero> public var adds: Int64 = 0
    @Default<Zero> public var updates: Int64 = 0
    @Default<Zero> public var deletes: Int64 = 0
    @Default<Zero> public var excluded: Int64 = 0
    @Default<Zero> public var bytes: Int64 = 0
    public var sample: PreviewSample = PreviewSample()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        _adds = try c.decode(Default<Zero>.self, forKey: .adds)
        _updates = try c.decode(Default<Zero>.self, forKey: .updates)
        _deletes = try c.decode(Default<Zero>.self, forKey: .deletes)
        _excluded = try c.decode(Default<Zero>.self, forKey: .excluded)
        _bytes = try c.decode(Default<Zero>.self, forKey: .bytes)
        sample = try c.decodeIfPresent(PreviewSample.self, forKey: .sample) ?? PreviewSample()
    }
    enum CodingKeys: String, CodingKey { case runId, adds, updates, deletes, excluded, bytes, sample }
    public var isPending: Bool { runId != nil && adds == 0 && updates == 0 && deletes == 0 && excluded == 0 }
}

public struct ExplainParams: Codable, Sendable {
    public var id: String
    public var path: String
    public init(id: String, path: String) { self.id = id; self.path = path }
}

public struct ExplainResult: Codable, Equatable, Sendable {
    @Default<False> public var included: Bool = false
    public var rule: String?
    public init(included: Bool, rule: String?) { self.included = included; self.rule = rule }
}

public struct HistoryParams: Codable, Sendable {
    public var id: String
    public var limit: Int
    public init(id: String, limit: Int = 20) { self.id = id; self.limit = limit }
}

public struct HistoryResult: Codable, Sendable { @Default<EmptyList<RunSummary>> public var runs: [RunSummary] = [] }

// MARK: - Action Center

public struct ActionChoice: Codable, Equatable, Hashable, Identifiable, Sendable {
    @Default<EmptyString> public var id: String = ""
    @Default<EmptyString> public var label: String = ""
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct Action: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, LenientEnum {
        case conflict, authExpired, maxDeleteAbort, error, quotaFull, permission, info
        public static var fallback: Kind { .info }
    }
    public enum Severity: String, LenientEnum { case info, warning, error; public static var fallback: Severity { .info } }
    @Default<EmptyString> public var id: String = ""
    public var jobId: String?
    @Default<FallbackCase<Kind>> public var kind: Kind = .info
    @Default<FallbackCase<Severity>> public var severity: Severity = .info
    @Default<EmptyString> public var title: String = ""
    @Default<EmptyString> public var message: String = ""
    public var path: String?
    @Default<EmptyString> public var createdAt: String = ""
    @Default<False> public var resolved: Bool = false
    @Default<EmptyList<ActionChoice>> public var choices: [ActionChoice] = []
    /// Kind-specific extras (e.g. accountId for authExpired).
    public var data: JSONValue?
    public init(id: String, jobId: String? = nil, kind: Kind, severity: Severity, title: String, message: String, path: String? = nil, createdAt: String = "", resolved: Bool = false, choices: [ActionChoice] = []) {
        self.id = id; self.jobId = jobId; self.kind = kind; self.severity = severity; self.title = title; self.message = message
        self.path = path; self.createdAt = createdAt; self.resolved = resolved; self.choices = choices
    }
    public var needsAttention: Bool { !resolved && (severity != .info || kind != .info) }
}

public struct ActionsListParams: Codable, Sendable { public var includeResolved: Bool; public init(includeResolved: Bool = false) { self.includeResolved = includeResolved } }
public struct ActionsResult: Codable, Sendable { @Default<EmptyList<Action>> public var actions: [Action] = [] }
public struct ResolveParams: Codable, Sendable { public var id: String; public var choice: String; public init(id: String, choice: String) { self.id = id; self.choice = choice } }
public struct ActionResult: Codable, Sendable { public var action: Action }

// MARK: - Logs

public struct LogLine: Codable, Equatable, Identifiable, Hashable, Sendable {
    public enum Level: String, LenientEnum, Comparable {
        case debug, info, notice, warn, error
        public static var fallback: Level { .info }
        public var rank: Int { Self.allCases.firstIndex(of: self) ?? 1 }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }
    public var id: String { ts + "|" + (runId ?? "") + "|" + msg + "|" + (path ?? "") }
    @Default<EmptyString> public var ts: String = ""
    @Default<FallbackCase<Level>> public var level: Level = .info
    public var jobId: String?
    public var runId: String?
    @Default<EmptyString> public var msg: String = ""
    public var path: String?
    public init(ts: String, level: Level, jobId: String? = nil, runId: String? = nil, msg: String, path: String? = nil) {
        self.ts = ts; self.level = level; self.jobId = jobId; self.runId = runId; self.msg = msg; self.path = path
    }
}

public struct LogQueryParams: Codable, Sendable {
    public var jobId: String?
    public var level: String?
    public var search: String?
    public var since: String?
    public var until: String?
    public var limit: Int
    public var before: String?
    public init(jobId: String? = nil, level: String? = nil, search: String? = nil, since: String? = nil, until: String? = nil, limit: Int = 500, before: String? = nil) {
        self.jobId = jobId; self.level = level; self.search = search; self.since = since; self.until = until; self.limit = limit; self.before = before
    }
}

public struct LogQueryResult: Codable, Sendable { @Default<EmptyList<LogLine>> public var lines: [LogLine] = [] }

public struct LogExportParams: Codable, Sendable {
    public var jobId: String?
    public var format: String
    public var dest: String
    public init(jobId: String?, format: String, dest: String) { self.jobId = jobId; self.format = format; self.dest = dest }
}

public struct DestParams: Codable, Sendable { public var dest: String; public init(dest: String) { self.dest = dest } }
public struct PathResult: Codable, Sendable { @Default<EmptyString> public var path: String = "" }

// MARK: - Settings (daemon-side)

public struct BandwidthSlot: Codable, Equatable, Hashable, Sendable {
    public var days: [Int]
    public var from: String
    public var to: String
    @Nullable public var upKBps: Int?
    @Nullable public var downKBps: Int?
    public init(days: [Int], from: String, to: String, upKBps: Int?, downKBps: Int?) {
        self.days = days; self.from = from; self.to = to; self.upKBps = upKBps; self.downKBps = downKBps
    }
}

public struct DaemonSettings: Codable, Equatable, Sendable {
    public struct Defaults: Codable, Equatable, Sendable {
        @Default<FallbackCase<SyncDirection>> public var direction: SyncDirection = .upload
        @Default<FallbackCase<ConflictPolicy>> public var conflictPolicy: ConflictPolicy = .keepBoth
        @Default<FallbackCase<DeletePolicy>> public var deletePolicy: DeletePolicy = .archive
        @Default<Ten> public var debounceSec: Int = 10
        @Default<Zero> public var minAgeSec: Int64 = 0
        @Default<TwentyFive> public var maxDeletePercent: Int = 25
        @Default<True> public var dryRunFirst: Bool = true
        @Default<RecommendedPresets> public var presets: [String] = FilterPreset.recommended
        public init() {}
    }
    public struct Network: Codable, Equatable, Sendable {
        @Default<False> public var allowCellular: Bool = false
        @Default<False> public var allowExpensive: Bool = false
        @Default<EmptyList<BandwidthSlot>> public var bwSchedule: [BandwidthSlot] = []
        @Nullable public var proxy: String?
        public init() {}
    }
    public struct Logs: Codable, Equatable, Sendable {
        @Default<InfoLevel> public var level: String = "info"
        @Default<Thirty> public var retentionDays: Int = 30
        public init() {}
    }
    public struct Engine: Codable, Equatable, Sendable {
        @Default<Four> public var transfers: Int = 4
        @Default<Eight> public var checkers: Int = 8
        @Default<ZeroInt> public var tpsLimit: Int = 0
        public var memoryLimitMB: Int?
        public init() {}
    }
    public var defaults = Defaults()
    public var network = Network()
    public var logs = Logs()
    public var engine = Engine()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try c.decodeIfPresent(Defaults.self, forKey: .defaults) ?? Defaults()
        network = try c.decodeIfPresent(Network.self, forKey: .network) ?? Network()
        logs = try c.decodeIfPresent(Logs.self, forKey: .logs) ?? Logs()
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? Engine()
    }
    enum CodingKeys: String, CodingKey { case defaults, network, logs, engine }
}

public struct SettingsResult: Codable, Sendable { public var settings: DaemonSettings }
public struct SettingsPatchParams: Codable, Sendable { public var patch: DaemonSettings; public init(patch: DaemonSettings) { self.patch = patch } }

// MARK: - Tools

public struct DedupeFile: Codable, Equatable, Identifiable, Sendable {
    @Default<EmptyString> public var id: String = ""
    @Default<EmptyString> public var path: String = ""
    @Default<Zero> public var size: Int64 = 0
    @Default<EmptyString> public var modTime: String = ""
}
public struct DedupeGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    @Default<EmptyString> public var name: String = ""
    @Default<EmptyList<DedupeFile>> public var files: [DedupeFile] = []
}
public struct DedupeScanParams: Codable, Sendable { public var accountId: String; public var path: String }
public struct DedupeScanResult: Codable, Sendable { @Default<EmptyList<DedupeGroup>> public var groups: [DedupeGroup] = [] }
public struct DedupeApplyParams: Codable, Sendable { public var accountId: String; public var path: String; public var mode: String }
public struct DedupeApplyResult: Codable, Sendable { @Default<ZeroInt> public var removed: Int = 0; @Default<ZeroInt> public var renamed: Int = 0 }

// MARK: - Notifications

public struct JobStateNote: Codable, Equatable, Sendable { public var jobId: String; public var status: JobStatus }
public struct JobProgressNote: Codable, Equatable, Sendable {
    public var jobId: String
    public var runId: String?
    public var progress: SyncProgress
}
public struct OverallProgress: Codable, Equatable, Sendable {
    @Default<ZeroInt> public var running: Int = 0
    @Default<Zero> public var bytes: Int64 = 0
    @Default<Zero> public var totalBytes: Int64 = 0
    @Default<ZeroDouble> public var percent: Double = 0
    @Default<ZeroDouble> public var speed: Double = 0
    public var eta: Double?
    public init(running: Int = 0, bytes: Int64 = 0, totalBytes: Int64 = 0, percent: Double = 0, speed: Double = 0, eta: Double? = nil) {
        self.running = running; self.bytes = bytes; self.totalBytes = totalBytes; self.percent = percent; self.speed = speed; self.eta = eta
    }
}
public struct ActionNote: Codable, Equatable, Sendable { public var action: Action }
public struct LogLineNote: Codable, Equatable, Sendable { public var line: LogLine }
public struct HealthNote: Codable, Equatable, Sendable {
    @Default<True> public var ok: Bool = true
    public var message: String?
}
public struct PreviewNote: Codable, Equatable, Sendable {
    public var jobId: String?
    public var runId: String?
    public var result: PreviewResult?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        // Accept either {result:{…}} / {preview:{…}} or the counts inline.
        if let r = try c.decodeIfPresent(PreviewResult.self, forKey: .result) { result = r }
        else if let r = try c.decodeIfPresent(PreviewResult.self, forKey: .preview) { result = r }
        else { result = try? PreviewResult(from: decoder) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(jobId, forKey: .jobId); try c.encodeIfPresent(runId, forKey: .runId); try c.encodeIfPresent(result, forKey: .result)
    }
    enum CodingKeys: String, CodingKey { case jobId, runId, result, preview }
}

// MARK: - Filter presets

public struct FilterPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let rules: [String]

    public static let recommended = ["vcs", "ide", "deps", "osjunk"]

    /// Canonical copy of the PROTOCOL.md table (the daemon is the source of truth; this is for display).
    public static let all: [FilterPreset] = [
        .init(id: "vcs", title: "Version control", rules: [".git/**", ".svn/**", ".hg/**", ".bzr/**"]),
        .init(id: "ide", title: "IDE & agents", rules: [".vscode/**", ".idea/**", ".claude/**", ".cursor/**", ".fleet/**", ".zed/**"]),
        .init(id: "deps", title: "Dependencies", rules: ["node_modules/**", "vendor/**", ".venv/**", "venv/**", "__pycache__/**", ".pnpm-store/**", "Pods/**"]),
        .init(id: "build", title: "Build output", rules: ["dist/**", "build/**", "target/**", ".next/**", ".nuxt/**", "out/**", "DerivedData/**", ".build/**"]),
        .init(id: "osjunk", title: "OS junk", rules: [".DS_Store", "._*", "Thumbs.db", "desktop.ini", ".Spotlight-V100/**", ".Trashes/**", ".fseventsd/**", "Icon\\r"]),
        .init(id: "caches", title: "Caches & temp", rules: [".cache/**", "*.tmp", "*.swp", "*~", ".sass-cache/**"]),
        .init(id: "dotfolders", title: "All dot-folders", rules: [".*/**"]),
        .init(id: "dotfiles", title: "All dot-files", rules: [".*"])
    ]

    public static func named(_ id: String) -> FilterPreset? { all.first { $0.id == id } }

    /// Turns a raw rule such as "- Icon\\r (preset osjunk)" into "OS junk · custom folder icon".
    public static func describe(rule: String) -> String {
        var pattern = rule.trimmingCharacters(in: .whitespaces)
        var group: String?
        if let open = pattern.range(of: " (", options: .backwards), pattern.hasSuffix(")") {
            let inside = pattern[open.upperBound..<pattern.index(before: pattern.endIndex)]
            let id = inside.hasPrefix("preset ") ? String(inside.dropFirst(7)) : String(inside)
            group = named(id)?.title ?? (id == "custom" ? "Your rule" : id)
            pattern = String(pattern[..<open.lowerBound])
        }
        if pattern.hasPrefix("- ") || pattern.hasPrefix("+ ") { pattern = String(pattern.dropFirst(2)) }
        let known: [String: String] = [
            ".DS_Store": "Finder view settings", "Icon\\r": "custom folder icon (hidden file)", "._*": "macOS extra file data",
            "Thumbs.db": "Windows thumbnails", "desktop.ini": "Windows folder settings", ".git/**": "Git repository",
            ".svn/**": "Subversion data", "node_modules/**": "npm packages", ".vscode/**": "VS Code settings",
            ".claude/**": "Claude Code settings", ".idea/**": "JetBrains settings", "vendor/**": "Composer/Go packages",
        ]
        let what = known[pattern] ?? pattern
        return [group, what].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Additions (daemon v1 extras)

public struct DismissAllResult: Codable, Sendable { @Default<ZeroInt> public var count: Int = 0 }

/// `config.export` result / `config.import` params: jobs + settings, never secrets.
public struct ConfigBundle: Codable, Sendable {
    public var settings: DaemonSettings?
    @Default<EmptyList<JobSpec>> public var jobs: [JobSpec] = []
    public init(settings: DaemonSettings?, jobs: [JobSpec]) { self.settings = settings; self.jobs = jobs }
}
