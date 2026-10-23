import Foundation

/// Looks up a localized string in the app bundle (String Catalog compiled by build-app.sh).
public func L(_ key: String) -> String { NSLocalizedString(key, bundle: .main, comment: "") }
/// Format strings: numbers come out in Persian digits when the UI is Persian (`Fmt.locale`).
public func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), locale: Fmt.locale, arguments: args) }

public enum Fmt {
    /// True when the app is showing its Persian localization (decided by the bundle, i.e. AppleLanguages).
    public static let isPersian: Bool = Bundle.main.preferredLocalizations.first?.hasPrefix("fa") == true

    /// Locale for numbers in formatted strings: Persian when the UI is Persian, otherwise nil (plain ASCII digits).
    public static let locale: Locale? = isPersian ? Locale(identifier: "fa_IR") : nil

    /// Separator for short inline lists ("a, b, c"); Persian uses its own comma.
    public static var listSeparator: String { isPersian ? "، " : ", " }

    /// Rewrites ASCII digits and separators as Persian ones when the UI is Persian. Only for strings
    /// that are purely numeric output (sizes, counts, durations), never for paths, names or versions.
    public static func digits(_ s: String) -> String {
        guard isPersian else { return s }
        var out = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if let d = c.wholeNumberValue, c.isASCII { out.append(Character(UnicodeScalar(0x06F0 + d)!)); continue }
            let prevDigit = i > 0 && chars[i - 1].isASCII && chars[i - 1].isNumber
            let nextDigit = i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber
            if c == ".", prevDigit, nextDigit { out.append("\u{066B}"); continue }
            if c == ",", prevDigit, nextDigit { out.append("\u{066C}"); continue }
            if c == "%" { out.append("\u{066A}"); continue }
            out.append(c)
        }
        return out
    }

    /// Google Drive "Computers" virtual paths (see the daemon's engine/remote.go):
    /// "@computers" and "@computer:<folderID>:<name>/sub".
    public static func computer(_ p: String) -> (id: String, name: String, sub: String)? {
        guard p.hasPrefix("@computer:") else { return nil }
        let rest = p.dropFirst("@computer:".count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let id = String(rest[..<colon])
        let after = rest[rest.index(after: colon)...]
        let parts = after.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return (id, String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
    }

    /// Remote path as shown to people: "Backups/Projects", "Computers/My Mac/Desktop".
    public static func remote(_ p: String) -> String {
        if p == "@computers" { return L("Computers") }
        if let c = computer(p) { return L("Computers") + "/" + c.name + (c.sub.isEmpty ? "" : "/" + c.sub) }
        return p
    }

    /// Decimal (Finder-style) byte counts: "999 B", "1.5 MB", "12.3 GB", "120 GB".
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(max(0, value))
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return digits("\(Int(v)) B") }
        if v >= 100 { return digits("\(Int(v.rounded())) \(units[i])") }
        return digits(String(format: "%.1f %@", v, units[i]))
    }

    public static func speed(_ bytesPerSec: Double) -> String { bytes(Int64(bytesPerSec)) + "/s" }

    /// "8s", "3m 20s", "1h 05m", "2d 3h"; nil/negative/huge → "—".
    public static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 365 * 86400 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return L("%ds", s) }
        if s < 3600 { return L("%dm %02ds", s / 60, s % 60) }
        if s < 86400 { return L("%dh %02dm", s / 3600, (s % 3600) / 60) }
        return L("%dd %dh", s / 86400, (s % 86400) / 3600)
    }

    public static func percent(_ value: Double) -> String { digits("\(Int(max(0, min(100, value)).rounded(.down)))%") }

    public static func count(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return digits(f.string(from: NSNumber(value: value)) ?? "\(value)")
    }

    /// "1.2 GB of 4.0 GB"
    public static func bytesOfTotal(_ p: SyncProgress) -> String {
        p.totalBytes > 0 ? L("%@ of %@", bytes(p.bytes), bytes(p.totalBytes)) : bytes(p.bytes)
    }

    /// "120 of 900 files"
    public static func filesOfTotal(_ p: SyncProgress) -> String {
        p.totalFiles > 0 ? L("%@ of %@ files", count(p.files), count(p.totalFiles)) : L("%@ files", count(p.files))
    }

    /// One-line row summary: "1.2 GB of 4.0 GB · 120 of 900 files · 3.1 MB/s · 2m 10s left"
    public static func progressLine(_ p: SyncProgress) -> String {
        var parts = [bytesOfTotal(p), filesOfTotal(p)]
        if p.speed > 0 { parts.append(speed(p.speed)) }
        if let eta = p.eta, eta > 0 { parts.append(L("%@ left", self.eta(eta))) }
        return parts.joined(separator: " · ")
    }

    /// Short relative time: "just now", "5 min ago", "in 2 h", "3 d ago".
    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let delta = date.timeIntervalSince(now)
        let a = abs(delta)
        let past = delta < 0
        if a < 45 { return past ? L("just now") : L("in a moment") }
        if a < 3600 { let n = Int((a / 60).rounded()); return past ? L("%d min ago", n) : L("in %d min", n) }
        if a < 86400 { let n = Int((a / 3600).rounded()); return past ? L("%d h ago", n) : L("in %d h", n) }
        let n = Int((a / 86400).rounded())
        return past ? L("%d d ago", n) : L("in %d d", n)
    }

    public static func relative(_ rfc3339: String?, now: Date = Date()) -> String { relative(RFC3339.date(rfc3339), now: now) }

    public static func clock(_ rfc3339: String?) -> String {
        guard let d = RFC3339.date(rfc3339) else { return "—" }
        let f = DateFormatter()
        if let locale { f.locale = locale }
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "MMM d, HH:mm"
        return f.string(from: d)
    }

    /// Shortens a path for display, replacing the home directory with ~.
    public static func path(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

// MARK: - State labels

public struct StateLabel: Equatable, Sendable {
    public enum Tone: Sendable { case neutral, active, success, warning, danger, paused }
    public var title: String
    public var detail: String?
    public var symbol: String
    public var tone: Tone
}

public extension JobStatus {
    var label: StateLabel {
        switch state {
        case .idle:
            if let last = lastRun {
                if last.ok { return .init(title: L("Up to date"), detail: L("Synced %@", Fmt.relative(last.endedAt ?? last.startedAt)), symbol: "checkmark.circle.fill", tone: .success) }
                return .init(title: L("Last run failed"), detail: last.error, symbol: "exclamationmark.triangle.fill", tone: .danger)
            }
            return .init(title: L("Idle"), detail: L("Never synced"), symbol: "circle.dashed", tone: .neutral)
        case .queued: return .init(title: L("Queued"), detail: L("Starts when a slot is free"), symbol: "clock", tone: .neutral)
        case .running: return .init(title: L("Syncing"), detail: progress.map { Fmt.percent($0.percent) }, symbol: "arrow.triangle.2.circlepath", tone: .active)
        case .paused: return .init(title: L("Paused"), detail: reason, symbol: "pause.circle.fill", tone: .paused)
        case .waiting: return .init(title: L("Waiting"), detail: reason ?? L("Waiting for the right conditions"), symbol: "hourglass", tone: .warning)
        case .error: return .init(title: L("Error"), detail: reason ?? lastRun?.error, symbol: "xmark.octagon.fill", tone: .danger)
        case .needsBaseline: return .init(title: L("Needs first sync"), detail: L("Review the preview, then run the baseline"), symbol: "arrow.left.arrow.right.circle", tone: .warning)
        }
    }
}

public extension SyncDirection {
    var title: String {
        switch self {
        case .upload: return L("Upload only")
        case .download: return L("Download only")
        case .twoWay: return L("Two-way sync")
        }
    }
    var explanation: String {
        switch self {
        case .upload: return L("Back up this Mac to the cloud. Changes in the cloud never touch your files.")
        case .download: return L("Keep a local copy of a cloud folder. Local edits are overwritten by the cloud.")
        case .twoWay: return L("Both sides stay identical. Edits and deletions flow in both directions.")
        }
    }
    var symbol: String {
        switch self {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .twoWay: return "arrow.up.arrow.down.circle"
        }
    }
}

public extension DeletePolicy {
    var title: String {
        switch self {
        case .mirror: return L("Mirror deletions")
        case .archive: return L("Archive deleted files")
        case .never: return L("Never delete")
        }
    }
    var explanation: String {
        switch self {
        case .mirror: return L("Deleting a file on one side deletes it on the other.")
        case .archive: return L("Deleted files move to a dated archive folder and are purged after the retention period.")
        case .never: return L("Files are only added or updated, never removed.")
        }
    }
}

public extension ConflictPolicy {
    var title: String {
        switch self {
        case .newer: return L("Newer wins")
        case .keepBoth: return L("Keep both")
        case .preferLocal: return L("Prefer this Mac")
        case .preferRemote: return L("Prefer the cloud")
        case .ask: return L("Ask me")
        }
    }
}

public extension Account.Status {
    var title: String {
        switch self {
        case .ok: return L("Connected")
        case .needsAuth: return L("Sign-in needed")
        case .error: return L("Error")
        case .unknown: return L("Unknown")
        }
    }
}

public extension Action.Kind {
    var symbol: String {
        switch self {
        case .conflict: return "arrow.triangle.branch"
        case .authExpired: return "key.slash"
        case .maxDeleteAbort: return "trash.slash"
        case .error: return "exclamationmark.octagon"
        case .quotaFull: return "externaldrive.badge.exclamationmark"
        case .permission: return "lock.trianglebadge.exclamationmark"
        case .info: return "info.circle"
        }
    }
}

/// SF Symbol per provider id (no trademarked logos).
public func providerSymbol(_ id: String) -> String {
    switch id {
    case "drive": return "triangle.bottomhalf.filled"
    case "onedrive": return "cloud.fill"
    case "dropbox": return "shippingbox.fill"
    case "box": return "cube.fill"
    case "pcloud": return "cloud.circle.fill"
    case "s3": return "server.rack"
    case "b2": return "flame.fill"
    case "azureblob": return "square.stack.3d.up.fill"
    case "gcs": return "square.stack.3d.down.right.fill"
    case "sftp": return "terminal.fill"
    case "ftp": return "network"
    case "webdav": return "globe"
    case "mega": return "m.circle.fill"
    case "protondrive": return "lock.shield.fill"
    case "local": return "externaldrive.fill"
    default: return "cloud"
    }
}
