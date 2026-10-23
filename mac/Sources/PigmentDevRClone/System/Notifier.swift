import AppKit
import CoreLocation
import Observation
import RCloneKit
import UserNotifications

/// True when running from a real .app bundle (UNUserNotificationCenter crashes otherwise).
var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

// MARK: - Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var lastStates: [String: JobStatus.State] = [:]

    func setUp() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        func a(_ id: String, _ title: String, fg: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: fg ? [.foreground] : [])
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "conflict", actions: [a("keepLocal", L("Keep this Mac's")), a("keepRemote", L("Keep the cloud's")), a("keepBoth", L("Keep both"))], intentIdentifiers: []),
            UNNotificationCategory(identifier: "authExpired", actions: [a("reconnect", L("Reconnect"), fg: true)], intentIdentifiers: []),
            UNNotificationCategory(identifier: "maxDeleteAbort", actions: [a("runAnyway", L("Run anyway")), a("open", L("Review"), fg: true)], intentIdentifiers: []),
            UNNotificationCategory(identifier: "error", actions: [a("retry", L("Retry")), a("open", L("Open"), fg: true)], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plain", actions: [], intentIdentifiers: [])
        ])
    }

    func handle(_ event: DaemonEvent, prefs: Prefs) {
        let model = AppEnvironment.shared.model
        switch event {
        case .actionNew(let action):
            updateBadge(model)
            guard !action.resolved else { return }
            let wanted = action.kind == .conflict ? prefs.notifyConflicts : (action.severity != .info && prefs.notifyErrors)
            guard wanted else { return }
            let category = ["conflict", "authExpired", "maxDeleteAbort"].contains(action.kind.rawValue) ? action.kind.rawValue : (action.severity == .error ? "error" : "plain")
            post(id: action.id, title: action.title, body: action.message + (action.path.map { "\n" + $0 } ?? ""), category: category,
                 info: ["actionId": action.id, "jobId": action.jobId ?? ""], prefs: prefs)
        case .actionUpdated(let action):
            updateBadge(model)
            if action.resolved, isBundledApp { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [action.id]) }
        case .jobState(let note):
            let previous = lastStates[note.jobId]
            lastStates[note.jobId] = note.status.state
            let name = model.job(note.jobId)?.name ?? L("Sync job")
            if previous == .running, note.status.state == .idle, let run = note.status.lastRun, run.ok, !run.dryRun, prefs.notifyCompleted {
                post(id: "done-" + run.id, title: L("%@ is up to date", name), body: L("%@ files · %@", Fmt.count(run.files), Fmt.bytes(run.bytes)),
                     category: "plain", info: ["jobId": note.jobId], prefs: prefs)
            }
            if note.status.state == .waiting, previous != .waiting, prefs.notifyPaused {
                post(id: "wait-" + note.jobId, title: L("%@ is waiting", name), body: note.status.reason ?? L("Held back by a network or power rule."),
                     category: "plain", info: ["jobId": note.jobId], prefs: prefs)
            }
            if note.status.state == .error, previous != .error, prefs.notifyErrors {
                post(id: "err-" + note.jobId, title: L("%@ failed", name), body: note.status.reason ?? note.status.lastRun?.error ?? "",
                     category: "plain", info: ["jobId": note.jobId], prefs: prefs)
            }
        case .connection(.connected):
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.updateBadge(model)
                for j in model.jobs { self.lastStates[j.id] = j.state }
            }
        default:
            break
        }
    }

    func updateBadge(_ model: AppModel) {
        let n = model.attentionCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func post(id: String, title: String, body: String, category: String, info: [String: String], prefs: Prefs) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        content.threadIdentifier = info["jobId"] ?? "general"
        if prefs.isQuiet() {
            content.interruptionLevel = .passive
        } else if prefs.notifySound {
            content.sound = .default
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let actionID = info["actionId"] as? String
        let jobID = info["jobId"] as? String
        let choice = response.actionIdentifier
        await MainActor.run {
            let env = AppEnvironment.shared
            if choice == UNNotificationDefaultActionIdentifier || choice == "open" || choice == "reconnect" {
                if choice == "reconnect" {
                    let action = env.model.actions.first { $0.id == actionID }
                    env.router.reconnectAccountID = action?.data?["accountId"]?.stringValue ?? env.model.job(action?.jobId ?? jobID)?.accountId
                    env.router.show(.accounts)
                }
                else if actionID != nil { env.router.show(.actions) }
                else if let jobID, !jobID.isEmpty { env.router.show(.jobs, job: jobID) }
                return
            }
            if let actionID, let action = env.model.actions.first(where: { $0.id == actionID }) {
                Task { await env.model.resolve(action, choice: choice) }
            }
        }
    }
}

// MARK: - Permissions

@MainActor
@Observable
final class Permissions: NSObject, CLLocationManagerDelegate {
    static let shared = Permissions()
    enum Status { case granted, denied, unknown }

    var notifications: Status = .unknown
    var fullDiskAccess: Status = .unknown
    var location: Status = .unknown

    @ObservationIgnored private lazy var locationManager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        return m
    }()

    func refresh() {
        if isBundledApp {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let status: Status = switch s.authorizationStatus {
                case .authorized, .provisional: .granted
                case .denied: .denied
                default: .unknown
                }
                Task { @MainActor in self.notifications = status }
            }
        }
        let tcc = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        fullDiskAccess = FileHandle(forReadingAtPath: tcc) != nil ? .granted : .unknown
        location = Self.map(locationManager.authorizationStatus)
    }

    private static func map(_ s: CLAuthorizationStatus) -> Status {
        switch s {
        case .authorizedAlways, .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    func requestNotifications() {
        guard isBundledApp else { return }
        if notifications == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func requestLocation() {
        if location == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.location = Self.map(manager.authorizationStatus)
            AppEnvironment.shared.system.refreshSSID()
        }
    }
}
