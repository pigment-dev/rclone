import AppKit
import RCloneKit
import ServiceManagement
import SwiftUI

/// Long-lived app services. Created once at launch.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let prefs = Prefs()
    let router = Router()
    let model = AppModel()
    let launcher = DaemonLauncher()
    let client: DaemonClient
    let icon: MenuIconController
    let system: SystemMonitor
    let notifier = Notifier()
    let updater = Updater()

    private init() {
        PDFont.register()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        client = DaemonClient(socketPath: launcher.socketPath, clientVersion: version)
        icon = MenuIconController(model: model, prefs: prefs)
        system = SystemMonitor(client: client)
        model.attach(client)
        // Decided before any scene exists; MainWindow dismisses itself on first appearance.
        router.startHidden = prefs.startMinimised && prefs.onboarded && !launcher.demo
        let launcher = self.launcher
        let notifier = self.notifier
        let prefs = self.prefs
        let system = self.system
        model.onEvent = { event in
            notifier.handle(event, prefs: prefs)
            if case .connection(.connected) = event { system.pushNow() }
        }
        Task {
            await client.setBeforeConnect { attempt in await launcher.ensureRunning(attempt: attempt) }
            await client.start()
        }
        system.start()
        DebugHooks.apply(self)
    }
}

@main
struct PigmentDevRCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        Window("PigmentDev rClone", id: "main") {
            MainWindow()
                .environment(env.model)
                .environment(env.prefs)
                .environment(env.router)
                .environment(\.layoutDirection, env.prefs.layoutDirection)
                .environment(\.locale, env.prefs.locale)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Sync Job…") { env.router.addJob() }.keyboardShortcut("n")
            }
            CommandMenu("Sync") {
                Button("Sync All Now") { Task { for j in env.model.jobs where j.enabled { await env.model.run(j.id) } } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Pause All") { Task { await env.model.pauseAll(.untilResumed) } }
                Button("Resume All") { Task { await env.model.resumeAll() } }
            }
        }

        MenuBarExtra(isInserted: Binding(get: { env.prefs.showMenuBarIcon }, set: { env.prefs.showMenuBarIcon = $0 })) {
            MenuBarView()
                .environment(env.model)
                .environment(env.prefs)
                .environment(env.router)
                .environment(\.layoutDirection, env.prefs.layoutDirection)
                .environment(\.locale, env.prefs.locale)
        } label: {
            MenuBarLabel(icon: env.icon, router: env.router)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(env.model)
                .environment(env.prefs)
                .environment(env.router)
                .environment(\.layoutDirection, env.prefs.layoutDirection)
                .environment(\.locale, env.prefs.locale)
                .frame(width: 720, height: 600)
        }
    }
}

/// The menu bar label. Also captures `openWindow` so non-view code (URL scheme, intents) can open the window.
struct MenuBarLabel: View {
    var icon: MenuIconController
    var router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: icon.image)
            .accessibilityLabel(icon.accessibilityLabel)
            .onAppear {
                router.openMainWindow = { openWindow(id: "main") }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM/SIGINT (kill, launchctl, Ctrl-C) → normal termination so the demo daemon is cleaned up.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        MainActor.assumeIsolated {
            let env = AppEnvironment.shared
            env.prefs.applyActivationPolicy()
            env.prefs.applyAppearance()
            env.notifier.setUp()
            if env.prefs.autoCheckUpdates { env.updater.startAutomaticChecks(channel: env.prefs.updateChannel) }
            let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            if launchedAtLogin && env.prefs.onboarded && !env.prefs.startMinimised {
                // Launched as a login item: stay in the menu bar.
                for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true { w.close() }
            }
            if !env.prefs.onboarded && !env.launcher.demo {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { env.router.addJob(firstRun: true) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppEnvironment.shared.router.bringToFront() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { DeepLink.handle(url) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppEnvironment.shared.launcher.cleanup()
        }
    }
}

/// `pdrclone://job/<id>`, `pdrclone://actions`, `pdrclone://add`, `pdrclone://logs`, `pdrclone://settings`.
@MainActor
enum DeepLink {
    static func handle(_ url: URL) {
        guard url.scheme == "pdrclone" else { return }
        let r = AppEnvironment.shared.router
        let host = url.host ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "job", "jobs":
            if let id = parts.first { r.show(.jobs, job: id) } else { r.show(.jobs) }
        case "actions": r.show(.actions)
        case "logs": r.show(.logs)
        case "accounts": r.show(.accounts)
        case "settings": r.show(.settings)
        case "add": r.addJob()
        default: r.show(.dashboard)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
