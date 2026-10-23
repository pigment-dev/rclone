import AppKit
import RCloneKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", sync = "Sync", filters = "Filters", network = "Network", power = "Power",
         notifications = "Notifications", accounts = "Accounts", advanced = "Advanced", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sync: return "arrow.triangle.2.circlepath"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .network: return "wifi"
        case .power: return "battery.75percent"
        case .notifications: return "bell"
        case .accounts: return "key"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    var embedded = false
    @Environment(AppModel.self) private var model
    @State private var tab: SettingsTab = ProcessInfo.processInfo.environment["PDRCLONE_SETTINGS_TAB"].flatMap { SettingsTab(rawValue: $0) } ?? .general
    @State private var draft = DaemonSettings()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if embedded { PageHeader(title: "Settings", subtitle: "Make PigmentDev rClone work the way you do.") }
            tabBar
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .sync: SyncDefaultsSettings(settings: $draft)
                case .filters: FilterSettings(settings: $draft)
                case .network: NetworkSettings(settings: $draft)
                case .power: PowerSettings()
                case .notifications: NotificationSettings()
                case .accounts: AccountsSettings()
                case .advanced: AdvancedSettings(settings: $draft)
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !embedded { Spacer(minLength: 0) }
        }
        .padding(embedded ? 0 : 24)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: .topLeading)
        .background { if !embedded { Backdrop() } }
        .onAppear(perform: syncFromModel)
        .onChange(of: model.settings) { _, _ in syncFromModel() }
        .onChange(of: draft) { _, new in
            guard loaded, new != model.settings else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await model.saveSettings(new)
            }
        }
    }

    private func syncFromModel() {
        if let s = model.settings, s != draft { draft = s }
        loaded = model.settings != nil
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { t in
                    Button { tab = t } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t.symbol).font(.system(size: 11.5, weight: .semibold))
                            Text(LocalizedStringKey(t.rawValue)).font(PDFont.text(12.5, .semibold))
                        }
                        .foregroundStyle(tab == t ? Color.white : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(tab == t ? Brand.orange : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .pdGlass(in: Capsule())
        }
    }
}

/// A titled glass group of settings rows.
struct SettingsGroup<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .toggleStyle(PDSwitchStyle())
                .tint(Brand.orange)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pdGlass(radius: 20)
            if let footer { Text(LocalizedStringKey(footer)).font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted).padding(.leading, 4) }
        }
        .font(PDFont.text(13))
    }
}

struct DisconnectedNote: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.settings == nil {
            Label("These settings live in the sync service. Connect to it to change them.", systemImage: "bolt.horizontal.circle")
                .font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(Prefs.self) private var prefs
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var updater = AppEnvironment.shared.updater
    @AppStorage(Surface.styleKey) private var surfaceStyle = "glass"
    @AppStorage(Surface.frostKey) private var glassFrost = 0.5

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Startup") {
                Toggle("Open PigmentDev rClone at login", isOn: Binding(get: { loginItem }, set: { on in
                    do { try LoginItem.set(on); loginItem = LoginItem.isEnabled; loginError = nil } catch { loginError = error.localizedDescription; loginItem = LoginItem.isEnabled }
                }))
                if let loginError { Text(loginError).font(PDFont.text(11.5)).foregroundStyle(Brand.red) }
                Toggle("Start with the window closed", isOn: $prefs.startMinimised)
                Text("The sync service keeps running in the background even when the app is closed.").font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
            }
            SettingsGroup(title: "Appearance") {
                Toggle("Show in the Dock", isOn: $prefs.showInDock)
                Toggle("Show in the menu bar", isOn: $prefs.showMenuBarIcon)
                Picker("Next to the menu bar icon", selection: $prefs.menuBarText) {
                    Text("Nothing").tag(MenuIconState.TextMode.none)
                    Text("Percent").tag(MenuIconState.TextMode.percent)
                    Text("Speed").tag(MenuIconState.TextMode.speed)
                }
                .pickerStyle(.segmented).fixedSize()
                Picker("Theme", selection: $prefs.appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented).fixedSize()
                Picker("Window style", selection: $surfaceStyle) {
                    Text("Glass").tag("glass"); Text("Flat").tag("flat")
                }
                .pickerStyle(.segmented).fixedSize()
                if surfaceStyle == "glass" {
                    HStack(spacing: 10) {
                        Text("Blur").font(PDFont.text(13))
                        Text("Clear").font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                        Slider(value: $glassFrost, in: 0...1).frame(maxWidth: 220)
                        Text("Frosted").font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                    }
                }
                Text(surfaceStyle == "glass" ? "Glass shows your desktop through a blur. Move the slider to make it clearer or more frosted." : "Flat uses solid light or dark colours, following the Theme above.")
                    .font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                Picker("Language", selection: $prefs.language) {
                    Text("System").tag("system"); Text("English").tag("en"); Text("فارسی").tag("fa")
                }
                Text("Language changes apply after relaunching.").font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
            }
            SettingsGroup(title: "Updates", footer: "Updates are downloaded from GitHub Releases and verified with PigmentDev's signing key. No telemetry, ever.") {
                Toggle("Check for updates automatically", isOn: $prefs.autoCheckUpdates)
                Picker("Channel", selection: $prefs.updateChannel) {
                    Text("Stable").tag("stable"); Text("Beta").tag("beta")
                }
                .pickerStyle(.segmented).fixedSize()
                UpdateRow(updater: updater, channel: prefs.updateChannel)
            }
        }
    }
}

struct UpdateRow: View {
    var updater: Updater
    var channel: String
    var body: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .idle: Text("Version \(updater.currentVersion)").foregroundStyle(Theme.textSecondary)
            case .checking: ProgressView().controlSize(.small); Text("Checking…")
            case .upToDate: Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
            case .available: Label("Version \(updater.latest?.version ?? "") is available", systemImage: "arrow.down.circle.fill").foregroundStyle(Brand.orange)
            case .downloading: ProgressView().controlSize(.small); Text("Downloading…")
            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.red).lineLimit(2)
            }
            Spacer()
            if updater.phase == .available {
                Button("Install & relaunch") { updater.install() }.pdPrimary()
            }
            Button("Check now") { updater.check(channel: channel) }.pdSecondary(large: false)
        }
        .font(PDFont.text(12.5))
    }
}

// MARK: - Sync defaults

struct SyncDefaultsSettings: View {
    @Binding var settings: DaemonSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DisconnectedNote()
            SettingsGroup(title: "New jobs start with", footer: "Existing jobs keep their own settings.") {
                Picker("Direction", selection: $settings.defaults.direction) { ForEach(SyncDirection.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Deletions", selection: $settings.defaults.deletePolicy) { ForEach(DeletePolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Conflicts", selection: $settings.defaults.conflictPolicy) { ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            SettingsGroup(title: "Timing & safety") {
                Stepper(value: $settings.defaults.debounceSec, in: 2...600) { Text("Wait \(settings.defaults.debounceSec) s after a change before syncing") }
                Stepper(value: Binding(get: { Int(settings.defaults.minAgeSec) }, set: { settings.defaults.minAgeSec = Int64($0) }), in: 0...3600, step: 5) {
                    Text("Skip files modified in the last \(settings.defaults.minAgeSec) s")
                }
                Stepper(value: $settings.defaults.maxDeletePercent, in: 0...100, step: 5) { Text("Delete guard: stop if a run deletes more than \(settings.defaults.maxDeletePercent)%") }
                Toggle("Dry-run preview before a job's first run", isOn: $settings.defaults.dryRunFirst)
            }
            SettingsGroup(title: "Engine", footer: "Higher numbers are faster on big folders but use more memory and API quota.") {
                Stepper(value: $settings.engine.transfers, in: 1...32) { Text("\(settings.engine.transfers) parallel transfers") }
                Stepper(value: $settings.engine.checkers, in: 1...64) { Text("\(settings.engine.checkers) parallel checkers") }
                Stepper(value: $settings.engine.tpsLimit, in: 0...100) { Text(settings.engine.tpsLimit == 0 ? L("No API rate limit") : L("At most %d API calls per second", settings.engine.tpsLimit)) }
            }
        }
    }
}

// MARK: - Filters

struct FilterSettings: View {
    @Binding var settings: DaemonSettings
    @Environment(Prefs.self) private var prefs
    @State private var newRule = ""

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 18) {
            DisconnectedNote()
            SettingsGroup(title: "Default presets for new jobs") {
                FlowLayout(spacing: 8) {
                    ForEach(FilterPreset.all) { p in
                        let on = settings.defaults.presets.contains(p.id)
                        ChipButton(title: L(p.title), selected: on, symbol: on ? "checkmark" : "plus") {
                            if on { settings.defaults.presets.removeAll { $0 == p.id } } else { settings.defaults.presets.append(p.id) }
                        }
                        .help(p.rules.joined(separator: "  "))
                    }
                }
            }
            SettingsGroup(title: "What each preset skips") {
                ForEach(FilterPreset.all) { p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(L(p.title)).font(PDFont.text(12.5, .semibold)).frame(width: 130, alignment: .leading)
                        Text(p.rules.joined(separator: "  ")).font(PDFont.mono(11, .regular)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            SettingsGroup(title: "Global exclude rules", footer: "Added to every new job's custom rules. Glob syntax, e.g. *.psd or /Exports/**.") {
                ForEach(prefs.globalRules, id: \.self) { r in
                    HStack {
                        Text(r).font(PDFont.mono(12, .medium))
                        Spacer()
                        IconButton(symbol: "trash", help: L("Remove"), tint: Brand.red) { prefs.globalRules.removeAll { $0 == r } }
                    }
                }
                HStack {
                    TextField("Pattern", text: $newRule).textFieldStyle(.roundedBorder).font(PDFont.mono(12, .medium))
                    Button("Add") { if !newRule.isEmpty { prefs.globalRules.append(newRule); newRule = "" } }
                }
            }
        }
    }
}

// MARK: - Network

struct NetworkSettings: View {
    @Binding var settings: DaemonSettings
    @Environment(Prefs.self) private var prefs
    @State private var grid = BandwidthGrid()
    @State private var proxy = ""
    @State private var allowDraft = ""
    @State private var denyDraft = ""
    @State private var gridLoaded = false
    private let system = AppEnvironment.shared.system

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 18) {
            DisconnectedNote()
            SystemStateCard(state: system.state)
            SettingsGroup(title: "Metered networks") {
                Toggle("Allow syncing over cellular or a phone hotspot", isOn: $settings.network.allowCellular)
                Toggle("Allow syncing on expensive / Low Data Mode networks", isOn: $settings.network.allowExpensive)
            }
            HStack(alignment: .top, spacing: 16) {
                TokenList(title: "Trusted Wi-Fi (default allow list)", tokens: $prefs.ssidAllow, placeholder: "Network name", draft: $allowDraft)
                TokenList(title: "Blocked Wi-Fi (default deny list)", tokens: $prefs.ssidDeny, placeholder: "Network name", draft: $denyDraft)
            }
            SettingsGroup(title: "Bandwidth timetable", footer: "Drag across the grid to mark hours when the limits below apply. Outside marked hours, transfers run at full speed.") {
                BandwidthGridEditor(grid: $grid)
                HStack(spacing: 18) {
                    LimitRow(title: "Upload", value: $grid.upKBps)
                    LimitRow(title: "Download", value: $grid.downKBps)
                    Spacer()
                    Button("Clear") { grid = BandwidthGrid(upKBps: grid.upKBps, downKBps: grid.downKBps) }.buttonStyle(.link)
                }
            }
            SettingsGroup(title: "Proxy", footer: "HTTP(S) proxy for all providers, e.g. http://proxy.local:8080. Leave empty to use none.") {
                TextField("http://host:port", text: $proxy)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { settings.network.proxy = proxy.isEmpty ? nil : proxy }
                    .onChange(of: proxy) { _, v in settings.network.proxy = v.isEmpty ? nil : v }
            }
        }
        .onAppear {
            guard !gridLoaded else { return }
            grid = BandwidthGrid(slots: settings.network.bwSchedule)
            if settings.network.bwSchedule.isEmpty { grid.upKBps = 1024 }
            proxy = settings.network.proxy ?? ""
            gridLoaded = true
        }
        .onChange(of: grid) { _, g in settings.network.bwSchedule = g.slots }
    }
}

struct SystemStateCard: View {
    var state: SystemState
    var body: some View {
        HStack(spacing: 18) {
            stat("Network", value: state.network.status == .satisfied ? state.network.interface.rawValue.capitalized : L("Offline"), symbol: "network")
            stat("Wi-Fi", value: state.network.ssid ?? "—", symbol: "wifi")
            stat("Metered", value: state.network.expensive || state.network.constrained ? L("Yes") : L("No"), symbol: "gauge.with.dots.needle.33percent")
            stat("Power", value: state.power.onBattery ? (state.power.batteryPercent.map { "\($0)%" } ?? L("Battery")) : L("Adapter"), symbol: "bolt.fill")
            stat("Free disk", value: Fmt.bytes(state.disk.freeBytes), symbol: "internaldrive")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdGlass(radius: 20)
    }
    private func stat(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)); SectionLabel(title) }.foregroundStyle(Theme.textMuted)
            Text(value).font(PDFont.text(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 7 × 24 click-and-drag grid.
struct BandwidthGridEditor: View {
    @Binding var grid: BandwidthGrid
    @State private var paintValue: Bool?
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let labelW: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Color.clear.frame(width: labelW, height: 1)
                GeometryReader { g in
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text(String(format: "%02d", h)).font(PDFont.mono(9, .medium)).foregroundStyle(Theme.textMuted)
                            .position(x: g.size.width * CGFloat(h) / 24 + 7, y: 6)
                    }
                }
                .frame(height: 12)
            }
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    ForEach(days, id: \.self) { d in
                        Text(LocalizedStringKey(d)).font(PDFont.mono(9.5, .medium)).foregroundStyle(Theme.textMuted).frame(width: labelW, height: 18, alignment: .leading)
                    }
                }
                GeometryReader { geo in
                    let cw = geo.size.width / 24, ch: CGFloat = 21
                    Canvas { ctx, _ in
                        for d in 0..<7 {
                            for h in 0..<24 {
                                let r = CGRect(x: CGFloat(h) * cw + 1, y: CGFloat(d) * ch + 1, width: cw - 2, height: ch - 3)
                                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(grid.cells[d][h] ? Brand.orange : Theme.track))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let h = Int(v.location.x / cw), d = Int(v.location.y / ch)
                        guard (0..<24).contains(h), (0..<7).contains(d) else { return }
                        if paintValue == nil { paintValue = !grid.cells[d][h] }
                        grid.set(day: d + 1, hour: h, paintValue!)
                    }.onEnded { _ in paintValue = nil })
                }
                .frame(height: 21 * 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Bandwidth timetable")
        .accessibilityValue("\(grid.slots.count) limited periods")
    }
}

// MARK: - Power

struct PowerSettings: View {
    @Environment(Prefs.self) private var prefs
    private let system = AppEnvironment.shared.system
    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 18) {
            SystemStateCard(state: system.state)
            SettingsGroup(title: "Battery", footer: "Per-job battery rules (pause on battery, minimum level) are in each job's Network section.") {
                Toggle("Pause all syncing in Low Power Mode", isOn: $prefs.pauseOnLowPower)
            }
            SettingsGroup(title: "Disk space") {
                Stepper(value: $prefs.pauseBelowFreeGB, in: 0...500) {
                    Text(prefs.pauseBelowFreeGB == 0 ? L("Never pause for low disk space") : L("Pause downloads when less than %d GB is free", prefs.pauseBelowFreeGB))
                }
            }
            SettingsGroup(title: "Sleep") {
                Text("When the Mac sleeps, transfers stop cleanly. Jobs with “When the Mac wakes up” run right after waking to catch up.")
                    .font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Notifications

struct NotificationSettings: View {
    @Environment(Prefs.self) private var prefs
    @State private var perms = Permissions.shared
    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 18) {
            if perms.notifications != .granted {
                HStack {
                    Label("Notifications are off for PigmentDev rClone.", systemImage: "bell.slash").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Allow notifications") { perms.requestNotifications() }.pdSecondary(large: false)
                }
                .padding(16).pdGlass(radius: 20)
            }
            SettingsGroup(title: "Notify me about") {
                Toggle("Conflicts that need a decision", isOn: $prefs.notifyConflicts)
                Toggle("Errors and expired sign-ins", isOn: $prefs.notifyErrors)
                Toggle("Finished syncs", isOn: $prefs.notifyCompleted)
                Toggle("Jobs paused by a network or power rule", isOn: $prefs.notifyPaused)
                Toggle("Play a sound", isOn: $prefs.notifySound)
            }
            SettingsGroup(title: "Quiet hours", footer: "During quiet hours notifications are delivered silently to Notification Center. The Action Center still collects everything.") {
                Toggle("Enable quiet hours", isOn: $prefs.quietHours)
                if prefs.quietHours {
                    HStack {
                        Text("From"); ClockPicker(value: $prefs.quietFrom)
                        Text("to"); ClockPicker(value: $prefs.quietTo)
                    }
                }
            }
        }
        .onAppear { perms.refresh() }
    }
}

// MARK: - Accounts

struct AccountsSettings: View {
    @Environment(Router.self) private var router
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "OAuth client IDs") {
                Text("Google Drive, OneDrive, Dropbox and Box sign-ins use rclone's shared client IDs by default. Shared IDs have rate limits; for heavy use you can create your own (free) and paste it when adding the account — open “Show advanced options” and fill in client_id and client_secret.")
                    .font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Step-by-step guide") { NSWorkspace.shared.open(URL(string: "https://pigment.dev/kb/rclone-use-your-own-oauth-client-id/")!) }.pdSecondary(large: false)
                    Button("Manage accounts") { router.show(.accounts) }.buttonStyle(.link)
                }
            }
            SettingsGroup(title: "Tokens") {
                Text("Access tokens refresh automatically. If a provider revokes one, the account shows “Sign-in needed” and the Action Center offers Reconnect.")
                    .font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @Binding var settings: DaemonSettings
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @State private var info: DaemonInfo?
    @State private var confirmReset = false
    @State private var message: String?
    private let launcher = AppEnvironment.shared.launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Sync service") {
                HStack(spacing: 10) {
                    ConnectionFooter()
                    Spacer()
                    Button("Restart") { launcher.restart(); Task { await model.client?.reconnect() } }.pdSecondary(large: false)
                }
                if let i = info {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        row("Daemon", "\(i.daemonVersion) (pid \(i.pid))")
                        row("rclone", i.rcloneVersion)
                        row("Uptime", Fmt.eta(Double(i.uptimeSec)))
                        row("Memory", Fmt.bytes(i.rssBytes))
                        row("Jobs running", "\(i.jobsRunning)")
                        row("Data folder", i.dataDir)
                    }
                    .font(PDFont.text(12.5))
                }
                row2("Socket", launcher.socketPath)
                row2("Startup", launcher.demo ? "Demo daemon" : launcher.overridden ? "External (PDRCLONE_SOCKET)" : agentText)
                if !launcher.lastNote.isEmpty { row2("Last action", launcher.lastNote) }
            }
            SettingsGroup(title: "Logs") {
                Picker("Log level", selection: $settings.logs.level) {
                    ForEach(["debug", "info", "notice", "warn", "error"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Stepper(value: $settings.logs.retentionDays, in: 1...365) { Text("Keep logs for \(settings.logs.retentionDays) days") }
            }
            SettingsGroup(title: "Data", footer: "Exports contain jobs and settings only — never passwords or tokens.") {
                HStack(spacing: 8) {
                    Button("Open data folder") {
                        let dir = model.hello?.dataDir.isEmpty == false ? URL(fileURLWithPath: model.hello!.dataDir) : DaemonPaths.appSupport
                        NSWorkspace.shared.open(dir)
                    }.pdSecondary(large: false)
                    Button("Export configuration…") { exportConfig() }.pdSecondary(large: false)
                    Button("Import configuration…") { importConfig() }.pdSecondary(large: false)
                }
                if let message { Text(message).font(PDFont.text(12)).foregroundStyle(Theme.textSecondary) }
            }
            SettingsGroup(title: "Reset") {
                Button("Reset app preferences…", role: .destructive) { confirmReset = true }.pdSecondary(large: false)
            }
        }
        .task { info = try? await model.client?.call("daemon.info", as: DaemonInfo.self) }
        .confirmationDialog("Reset app preferences?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                message = L("Preferences reset. Relaunch to see the welcome screen again.")
            }
        } message: { Text("Jobs, accounts and files are not affected.") }
    }

    private var agentText: String {
        switch launcher.agentStatus {
        case .enabled: return "LaunchAgent (enabled)"
        case .requiresApproval: return "LaunchAgent needs approval in System Settings → Login Items"
        case .notRegistered: return launcher.childRunning ? "Child process" : "LaunchAgent not registered"
        case .notFound: return launcher.childRunning ? "Child process" : "LaunchAgent not bundled"
        @unknown default: return "Unknown"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(LocalizedStringKey(k)).foregroundStyle(Theme.textMuted); Text(v).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
    }
    private func row2(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(k)).font(PDFont.text(12)).foregroundStyle(Theme.textMuted).frame(width: 90, alignment: .leading)
            Text(v).font(PDFont.mono(11, .regular)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).lineLimit(2)
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pdrclone-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            // Prefer the daemon's export (authoritative); fall back to what the app knows.
            var bundle: ConfigBundle
            if let c = model.client, let b = try? await c.call("config.export", as: ConfigBundle.self) { bundle = b }
            else { bundle = ConfigBundle(settings: model.settings, jobs: model.jobs.map(JobSpec.init)) }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try enc.encode(bundle).write(to: url); message = L("Exported %d jobs.", bundle.jobs.count) } catch { message = error.localizedDescription }
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(ConfigBundle.self, from: data) else { message = L("That file isn't a PigmentDev rClone export."); return }
        Task {
            guard let client = model.client else { return }
            if (try? await client.send("config.import", bundle, timeout: 60)) != nil {
                message = L("Imported %d jobs. Accounts must be connected again.", bundle.jobs.count)
            } else {
                if let s = bundle.settings { await model.saveSettings(s) }
                var n = 0
                for spec in bundle.jobs where (try? await client.call("jobs.create", CreateJobParams(job: spec), as: JobResult.self)) != nil { n += 1 }
                message = L("Imported %d of %d jobs. Accounts must be connected again.", n, bundle.jobs.count)
            }
            await model.refreshAll()
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                BrandMark(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PigmentDev rClone").font(PDFont.display(26, .black)).foregroundStyle(Theme.text)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))")
                        .font(PDFont.text(13)).foregroundStyle(Theme.textSecondary)
                    if let h = model.hello { Text("pdrcloned \(h.daemonVersion) · rclone \(h.rcloneVersion) · \(h.os)/\(h.arch)").font(PDFont.mono(11, .medium)).foregroundStyle(Theme.textMuted) }
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading).pdGlass(radius: Theme.cardRadius)
            SettingsGroup(title: "Links") {
                HStack(spacing: 10) {
                    link("GitHub", "https://github.com/pigment-dev/rclone")
                    link("Website", "https://pigment.dev/products/rclone/")
                    link("Report an issue", "https://github.com/pigment-dev/rclone/issues/new/choose")
                    link("Help", "https://pigment.dev/docs/rclone/")
                }
            }
            SettingsGroup(title: "Licenses") {
                license("PigmentDev rClone", "MIT License · © 2026 PigmentDev")
                license("rclone", "MIT License · © Nick Craig-Wood and contributors — the sync engine inside pdrcloned")
                license("Red Hat Display, Text & Mono", "SIL Open Font License 1.1 · © Red Hat, Inc.")
                Text("Free and open source. No telemetry, no accounts, no ads.").font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
            }
        }
    }
    private func link(_ t: String, _ u: String) -> some View {
        Button(LocalizedStringKey(t)) { NSWorkspace.shared.open(URL(string: u)!) }.pdSecondary(large: false)
    }
    private func license(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(PDFont.text(13, .semibold)).foregroundStyle(Theme.text)
            Text(text).font(PDFont.text(12)).foregroundStyle(Theme.textSecondary)
        }
    }
}
