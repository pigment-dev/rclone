import Foundation

public enum WizardStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, permissions, account, local, remote, direction, schedule, exclusions, network, preview, done

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: return L("Welcome")
        case .permissions: return L("Permissions")
        case .account: return L("Account")
        case .local: return L("This Mac")
        case .remote: return L("Cloud folder")
        case .direction: return L("Direction")
        case .schedule: return L("Schedule")
        case .exclusions: return L("Exclusions")
        case .network: return L("Network")
        case .preview: return L("Preview")
        case .done: return L("Done")
        }
    }

    public var symbol: String {
        switch self {
        case .welcome: return "hand.wave"
        case .permissions: return "lock.shield"
        case .account: return "person.crop.circle"
        case .local: return "laptopcomputer"
        case .remote: return "cloud"
        case .direction: return "arrow.up.arrow.down"
        case .schedule: return "calendar.badge.clock"
        case .exclusions: return "line.3.horizontal.decrease.circle"
        case .network: return "wifi"
        case .preview: return "eye"
        case .done: return "checkmark.seal"
        }
    }

    /// Steps shown for the first run vs. "Add job".
    public static func flow(firstRun: Bool) -> [WizardStep] {
        firstRun ? allCases : allCases.filter { $0 != .welcome && $0 != .permissions }
    }
}

public struct ValidationIssue: Equatable, Sendable, Identifiable {
    public var id: String { field + ":" + message }
    public var field: String
    public var message: String
    public init(_ field: String, _ message: String) { self.field = field; self.message = message }
}

public enum JobValidator {
    /// Returns the issues that block leaving `step`. `fileExists` is injectable for tests.
    public static func issues(for step: WizardStep, job: Job, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        switch step {
        case .welcome, .permissions, .remote, .done:
            break
        case .account:
            if job.accountId.isEmpty { out.append(.init("accountId", L("Choose or add an account."))) }
        case .local:
            if job.localPath.isEmpty { out.append(.init("localPath", L("Choose a folder on this Mac."))) }
            else if !job.localPath.hasPrefix("/") { out.append(.init("localPath", L("The folder path must be absolute."))) }
            else if !fileExists(job.localPath) { out.append(.init("localPath", L("That folder doesn't exist."))) }
            else if job.localPath == "/" { out.append(.init("localPath", L("Syncing the whole disk isn't supported."))) }
        case .direction:
            if job.deletePolicy == .archive, job.archiveRetentionDays < 1 {
                out.append(.init("archiveRetentionDays", L("Keep archived files for at least one day.")))
            }
            if !(0...100).contains(job.safety.maxDeletePercent) {
                out.append(.init("maxDeletePercent", L("The delete guard must be between 0 and 100%.")))
            }
        case .schedule:
            let t = job.triggers
            let any = t.onChange || t.intervalMin != nil || t.daily != nil || t.weekly != nil || t.cron != nil || t.onWake || t.manual
            if !any { out.append(.init("triggers", L("Pick at least one way to start this job."))) }
            if t.onChange, !(2...3600).contains(t.debounceSec) { out.append(.init("debounceSec", L("Wait between 2 seconds and an hour after a change."))) }
            if let i = t.intervalMin, i < 1 { out.append(.init("intervalMin", L("The interval must be at least one minute."))) }
            if let d = t.daily, !isValidClock(d) { out.append(.init("daily", L("Use a 24-hour time like 09:30."))) }
            if let w = t.weekly {
                if !(1...7).contains(w.day) { out.append(.init("weekly", L("Pick a weekday."))) }
                if !isValidClock(w.time) { out.append(.init("weekly", L("Use a 24-hour time like 09:30."))) }
            }
            if let c = t.cron, !isValidCron(c) { out.append(.init("cron", L("A cron expression has five fields, e.g. 0 */2 * * *."))) }
        case .exclusions:
            if job.filters.rules.contains(where: { $0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }) {
                out.append(.init("rules", L("Remove empty rules.")))
            }
            if let m = job.filters.maxSizeMB, m < 1 { out.append(.init("maxSizeMB", L("The size limit must be at least 1 MB."))) }
        case .network:
            if let b = job.network.minBatteryPercent, !(1...100).contains(b) { out.append(.init("minBatteryPercent", L("Battery level must be 1–100%."))) }
            if let u = job.limits.bwUpKBps, u < 1 { out.append(.init("bwUpKBps", L("Upload limit must be positive."))) }
            if let d = job.limits.bwDownKBps, d < 1 { out.append(.init("bwDownKBps", L("Download limit must be positive."))) }
            if !Set(job.network.ssidAllow).isDisjoint(with: job.network.ssidDeny) {
                out.append(.init("ssid", L("A network can't be both allowed and blocked.")))
            }
        case .preview:
            if job.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init("name", L("Give this job a name."))) }
        }
        return out
    }

    /// All issues for a complete job (used before jobs.create / jobs.update).
    public static func allIssues(_ job: Job, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ValidationIssue] {
        WizardStep.allCases.flatMap { issues(for: $0, job: job, fileExists: fileExists) }
    }

    public static func isValidClock(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// Light structural check of a 5-field cron expression (the daemon does the full parse).
    public static func isValidCron(_ s: String) -> Bool {
        let fields = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count == 1, fields[0].hasPrefix("@") {
            return ["@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@annually", "@midnight"].contains(String(fields[0]))
        }
        guard fields.count == 5 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789*/,-?LW#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return fields.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }
    }

    /// Suggests a job name from the local folder and account.
    public static func suggestedName(localPath: String, accountName: String?) -> String {
        let folder = (localPath as NSString).lastPathComponent
        guard !folder.isEmpty else { return accountName ?? L("New job") }
        if let accountName, !accountName.isEmpty { return "\(folder) → \(accountName)" }
        return folder
    }
}

public extension Job {
    /// A new job pre-filled from daemon defaults (or built-ins).
    static func draft(defaults: DaemonSettings.Defaults? = nil) -> Job {
        var job = Job()
        let d = defaults ?? DaemonSettings.Defaults()
        job.direction = d.direction
        job.conflictPolicy = d.conflictPolicy
        job.deletePolicy = d.deletePolicy
        job.archiveRetentionDays = 30
        job.filters = Filters(presets: d.presets.isEmpty ? FilterPreset.recommended : d.presets, minAgeSec: d.minAgeSec)
        job.triggers = Triggers(onChange: true, debounceSec: d.debounceSec > 0 ? d.debounceSec : 10)
        job.safety = Safety(maxDeletePercent: d.maxDeletePercent > 0 ? d.maxDeletePercent : 25, dryRunFirst: d.dryRunFirst)
        return job
    }
}

// MARK: - Bandwidth timetable grid

/// A 7×24 grid of hourly cells (day 1 = Monday … 7 = Sunday) converted to/from `bwSchedule` slots.
public struct BandwidthGrid: Equatable, Sendable {
    /// cells[day-1][hour] — true when the limit applies.
    public var cells: [[Bool]]
    public var upKBps: Int?
    public var downKBps: Int?

    public init(upKBps: Int? = 1024, downKBps: Int? = nil) {
        cells = Array(repeating: Array(repeating: false, count: 24), count: 7)
        self.upKBps = upKBps; self.downKBps = downKBps
    }

    public init(slots: [BandwidthSlot]) {
        self.init(upKBps: slots.first?.upKBps, downKBps: slots.first?.downKBps)
        for slot in slots {
            guard let from = Self.hour(slot.from), let to = Self.hour(slot.to, end: true) else { continue }
            for day in slot.days where (1...7).contains(day) {
                for h in from..<max(from, to) { cells[day - 1][h] = true }
            }
        }
    }

    public mutating func set(day: Int, hour: Int, _ on: Bool) {
        guard (1...7).contains(day), (0..<24).contains(hour) else { return }
        cells[day - 1][hour] = on
    }

    /// Contiguous runs per day, then identical runs merged across days.
    public var slots: [BandwidthSlot] {
        var runs: [(from: Int, to: Int, days: [Int])] = []
        for d in 0..<7 {
            var h = 0
            while h < 24 {
                guard cells[d][h] else { h += 1; continue }
                let start = h
                while h < 24, cells[d][h] { h += 1 }
                if let i = runs.firstIndex(where: { $0.from == start && $0.to == h }) { runs[i].days.append(d + 1) }
                else { runs.append((start, h, [d + 1])) }
            }
        }
        return runs.map {
            BandwidthSlot(days: $0.days, from: String(format: "%02d:00", $0.from), to: $0.to == 24 ? "24:00" : String(format: "%02d:00", $0.to),
                          upKBps: upKBps, downKBps: downKBps)
        }
    }

    static func hour(_ s: String, end: Bool = false) -> Int? {
        let p = s.split(separator: ":")
        guard let h = p.first.flatMap({ Int($0) }), (0...24).contains(h) else { return nil }
        let m = p.count > 1 ? Int(p[1]) ?? 0 : 0
        return end && m > 0 ? min(24, h + 1) : h
    }
}
