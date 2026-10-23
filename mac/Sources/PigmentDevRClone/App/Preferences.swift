import AppKit
import Observation
import RCloneKit
import SwiftUI

/// App-side preferences (daemon-side settings live in `DaemonSettings`).
@MainActor
@Observable
final class Prefs {
    private let d = UserDefaults.standard

    var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock"); applyActivationPolicy() } }
    var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var menuBarText: MenuIconState.TextMode { didSet { d.set(menuBarText.rawValue, forKey: "menuBarText") } }
    var appearance: String { didSet { d.set(appearance, forKey: "appearance"); applyAppearance() } }
    var language: String { didSet { d.set(language, forKey: "language"); applyLanguage() } }
    var startMinimised: Bool { didSet { d.set(startMinimised, forKey: "startMinimised") } }
    var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    var updateChannel: String { didSet { d.set(updateChannel, forKey: "updateChannel") } }
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    var notifyCompleted: Bool { didSet { d.set(notifyCompleted, forKey: "notifyCompleted") } }
    var notifyConflicts: Bool { didSet { d.set(notifyConflicts, forKey: "notifyConflicts") } }
    var notifyErrors: Bool { didSet { d.set(notifyErrors, forKey: "notifyErrors") } }
    var notifyPaused: Bool { didSet { d.set(notifyPaused, forKey: "notifyPaused") } }
    var notifySound: Bool { didSet { d.set(notifySound, forKey: "notifySound") } }
    var quietHours: Bool { didSet { d.set(quietHours, forKey: "quietHours") } }
    var quietFrom: String { didSet { d.set(quietFrom, forKey: "quietFrom") } }
    var quietTo: String { didSet { d.set(quietTo, forKey: "quietTo") } }

    var pauseOnLowPower: Bool { didSet { d.set(pauseOnLowPower, forKey: "pauseOnLowPower") } }
    var pauseBelowFreeGB: Int { didSet { d.set(pauseBelowFreeGB, forKey: "pauseBelowFreeGB") } }
    var ssidAllow: [String] { didSet { d.set(ssidAllow, forKey: "ssidAllow") } }
    var ssidDeny: [String] { didSet { d.set(ssidDeny, forKey: "ssidDeny") } }
    var globalRules: [String] { didSet { d.set(globalRules, forKey: "globalRules") } }

    init() {
        d.register(defaults: [
            "showInDock": true, "showMenuBarIcon": true, "menuBarText": "none", "appearance": "system", "language": "system",
            "startMinimised": false, "autoCheckUpdates": true, "updateChannel": "stable", "onboarded": false,
            "notifyCompleted": false, "notifyConflicts": true, "notifyErrors": true, "notifyPaused": false, "notifySound": true,
            "quietHours": false, "quietFrom": "22:00", "quietTo": "07:00", "pauseOnLowPower": true, "pauseBelowFreeGB": 2
        ])
        showInDock = d.bool(forKey: "showInDock")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        menuBarText = MenuIconState.TextMode(rawValue: d.string(forKey: "menuBarText") ?? "none") ?? .none
        appearance = d.string(forKey: "appearance") ?? "system"
        language = d.string(forKey: "language") ?? "system"
        startMinimised = d.bool(forKey: "startMinimised")
        autoCheckUpdates = d.bool(forKey: "autoCheckUpdates")
        updateChannel = d.string(forKey: "updateChannel") ?? "stable"
        onboarded = d.bool(forKey: "onboarded")
        notifyCompleted = d.bool(forKey: "notifyCompleted")
        notifyConflicts = d.bool(forKey: "notifyConflicts")
        notifyErrors = d.bool(forKey: "notifyErrors")
        notifyPaused = d.bool(forKey: "notifyPaused")
        notifySound = d.bool(forKey: "notifySound")
        quietHours = d.bool(forKey: "quietHours")
        quietFrom = d.string(forKey: "quietFrom") ?? "22:00"
        quietTo = d.string(forKey: "quietTo") ?? "07:00"
        pauseOnLowPower = d.bool(forKey: "pauseOnLowPower")
        pauseBelowFreeGB = d.integer(forKey: "pauseBelowFreeGB")
        ssidAllow = d.stringArray(forKey: "ssidAllow") ?? []
        ssidDeny = d.stringArray(forKey: "ssidDeny") ?? []
        globalRules = d.stringArray(forKey: "globalRules") ?? []
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func applyLanguage() {
        if language == "system" { d.removeObject(forKey: "AppleLanguages") } else { d.set([language], forKey: "AppleLanguages") }
    }

    /// Follows the localization the app is actually showing (a language change applies after relaunch,
    /// so flipping the layout before the strings change would mix RTL layout with English text).
    var layoutDirection: LayoutDirection {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: lang).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// Locale for SwiftUI formatting (dates, pickers, numbers): Persian when the UI is Persian.
    var locale: Locale { Fmt.locale ?? .current }

    /// True when the current time falls inside quiet hours.
    func isQuiet(now: Date = Date()) -> Bool {
        guard quietHours, JobValidator.isValidClock(quietFrom), JobValidator.isValidClock(quietTo) else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        func mins(_ s: String) -> Int { let p = s.split(separator: ":").compactMap { Int($0) }; return p[0] * 60 + p[1] }
        let a = mins(quietFrom), b = mins(quietTo)
        return a <= b ? (m >= a && m < b) : (m >= a || m < b)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, jobs, accounts, actions, logs, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .jobs: return "Jobs"
        case .accounts: return "Accounts"
        case .actions: return "Action Center"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .jobs: return "arrow.triangle.2.circlepath"
        case .accounts: return "person.crop.circle"
        case .actions: return "bell.badge"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

/// Navigation state shared by the window, menu bar, URL scheme and intents.
@MainActor
@Observable
final class Router {
    var selection: SidebarItem? = .dashboard
    var selectedJobID: String?
    var showWizard = false
    var wizardFirstRun = false
    var logJobFilter: String?
    var explainPath: String = ""
    /// Set to an account id to open the reconnect (re-auth) flow on the Accounts page.
    var reconnectAccountID: String?
    @ObservationIgnored var startHidden = false
    @ObservationIgnored var openMainWindow: (() -> Void)?

    func show(_ item: SidebarItem, job: String? = nil) {
        selection = item
        if let job { selectedJobID = job }
        bringToFront()
    }

    func addJob(firstRun: Bool = false) {
        wizardFirstRun = firstRun
        showWizard = true
        bringToFront()
    }

    func bringToFront() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
