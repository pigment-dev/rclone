import Foundation

/// Looks up a localized string in the app bundle (String Catalog compiled by build-app.sh).
public func L(_ key: String) -> String { NSLocalizedString(key, bundle: .main, comment: "") }
public func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

public enum Fmt {
    /// Decimal (Finder-style) byte counts: "999 B", "1.5 MB", "12.3 GB", "120 GB".
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(max(0, value))
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        if v >= 100 { return "\(Int(v.rounded())) \(units[i])" }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func speed(_ bytesPerSec: Double) -> String { bytes(Int64(bytesPerSec)) + "/s" }

    /// "8s", "3m 20s", "1h 05m", "2d 3h"; nil/negative/huge → "—".
    public static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 365 * 86400 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s < 86400 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    public static func percent(_ value: Double) -> String { "\(Int(max(0, min(100, value)).rounded(.down)))%" }

    public static func count(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "1.2 GB of 4.0 GB"
    public static func bytesOfTotal(_ p: SyncProgress) -> String {
        p.totalBytes > 0 ? "\(bytes(p.bytes)) of \(bytes(p.totalBytes))" : bytes(p.bytes)
    }

    /// "120 of 900 files"
    public static func filesOfTotal(_ p: SyncProgress) -> String {
        p.totalFiles > 0 ? "\(count(p.files)) of \(count(p.totalFiles)) files" : "\(count(p.files)) files"
    }

    /// One-line row summary: "1.2 GB of 4.0 GB · 120 of 900 files · 3.1 MB/s · 2m 10s left"
    public static func progressLine(_ p: SyncProgress) -> String {
        var parts = [bytesOfTotal(p), filesOfTotal(p)]
        if p.speed > 0 { parts.append(speed(p.speed)) }
        if let eta = p.eta, eta > 0 { parts.append(self.eta(eta) + " left") }
        return parts.joined(separator: " · ")
    }

    /// Short relative time: "just now", "5 min ago", "in 2 h", "3 d ago".
    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let delta = date.timeIntervalSince(now)
        let a = abs(delta)
        let text: String
        if a < 45 { return delta < 0 ? "just now" : "in a moment" }
        else if a < 3600 { text = "\(Int((a / 60).rounded())) min" }
        else if a < 86400 { text = "\(Int((a / 3600).rounded())) h" }
        else { text = "\(Int((a / 86400).rounded())) d" }
        return delta < 0 ? "\(text) ago" : "in \(text)"
    }

    public static func relative(_ rfc3339: String?, now: Date = Date()) -> String { relative(RFC3339.date(rfc3339), now: now) }

    public static func clock(_ rfc3339: String?) -> String {
        guard let d = RFC3339.date(rfc3339) else { return "—" }
        let f = DateFormatter()
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
                if last.ok { return .init(title: L("Up to date"), detail: L("Synced") + " " + Fmt.relative(last.endedAt ?? last.startedAt), symbol: "checkmark.circle.fill", tone: .success) }
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
