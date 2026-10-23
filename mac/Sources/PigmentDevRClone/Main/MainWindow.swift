import AppKit
import RCloneKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(Prefs.self) private var prefs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            ZStack(alignment: .top) {
                Backdrop()
                detail
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.lastError = nil }
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .frame(minWidth: 920, minHeight: 620)
        .tint(Brand.orange)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar { HeaderLogo() }
        .sheet(isPresented: $router.showWizard) {
            WizardView(firstRun: router.wizardFirstRun)
                .environment(model).environment(prefs).environment(router)
                .environment(\.layoutDirection, prefs.layoutDirection)
        }
        .onAppear {
            router.openMainWindow = { openWindow(id: "main") }
            if router.startHidden {
                router.startHidden = false
                dismissWindow(id: "main")
            }
        }
        .onOpenURL { DeepLink.handle($0) }
        .animation(.easeOut(duration: 0.2), value: model.lastError)
    }

    private var sidebar: some View {
        @Bindable var router = router
        return List(selection: $router.selection) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label(LocalizedStringKey(item.title), systemImage: item.symbol)
                        .labelStyle(SidebarLabelStyle())
                        .font(PDFont.text(13.5, .medium))
                        .badge(item == .actions ? model.attentionCount : 0)
                        .listItemTint(.fixed(Brand.orange))
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detail: some View {
        switch router.selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .jobs:
            if let id = router.selectedJobID, model.job(id) != nil { JobDetailView(jobID: id) } else { JobsListView() }
        case .accounts: AccountsView()
        case .actions: ActionCenterView()
        case .logs: LogsView()
        case .settings: ScrollView { SettingsView(embedded: true).padding(28) }
        }
    }
}

struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PDFont.text(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                if let h = model.hello, model.isConnected {
                    Text("pdrcloned \(h.daemonVersion) · rclone \(h.rcloneVersion)")
                        .font(PDFont.mono(9, .medium)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .pdGlass(radius: 14)
        .accessibilityElement(children: .combine)
    }
    var color: Color {
        switch model.connection {
        case .connected: return Brand.green
        case .connecting: return Brand.yellow
        default: return Brand.red
        }
    }
    var title: String {
        switch model.connection {
        case .connected: return L("Sync service running")
        case .connecting(let n): return n > 1 ? L("Reconnecting…") : L("Connecting…")
        case .disconnected: return L("Sync service offline")
        case .idle: return L("Starting…")
        }
    }
}

/// Window status bar: sync service state and versions on the left, current activity with a progress bar on the right.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(serviceColor).frame(width: 7, height: 7)
            Text(serviceTitle).font(PDFont.text(11.5, .semibold)).foregroundStyle(Theme.textSecondary).fixedSize()
            if let h = model.hello, model.isConnected {
                Text("pdrcloned \(h.daemonVersion) · rclone \(h.rcloneVersion)")
                    .font(PDFont.mono(10, .medium)).foregroundStyle(Theme.textMuted).fixedSize()
            }
            Divider().frame(height: 14)
            activity
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var activity: some View {
        let running = model.runningJobs
        if let job = running.first, model.isConnected {
            let o = model.overall
            let file = job.progress?.transferring.first?.name
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.orange)
                Text(running.count > 1 ? L("Syncing %d jobs", running.count) : L("Syncing %@", job.name))
                    .font(PDFont.text(11.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                if let file {
                    Text(file).font(PDFont.mono(10, .regular)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ProgressTrack(fraction: o.percent / 100, height: 5, indeterminate: o.totalBytes == 0)
                    .frame(width: 160)
                Text([Fmt.percent(o.percent), Fmt.speed(o.speed), o.eta.map { Fmt.eta($0) + " " + L("left") }].compactMap { $0 }.joined(separator: " · "))
                    .font(PDFont.numbers(11)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            }
        } else {
            HStack(spacing: 6) {
                let waiting = model.jobs.filter { $0.state == .waiting || $0.state == .paused }.count
                Image(systemName: waiting > 0 ? "pause.circle" : "checkmark.circle").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(waiting > 0 ? Theme.textMuted : Brand.green)
                Text(idleText(waiting: waiting)).font(PDFont.text(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func idleText(waiting: Int) -> String {
        if !model.isConnected { return L("Not syncing") }
        if model.jobs.isEmpty { return L("No sync jobs yet") }
        if waiting > 0 { return L("Idle · %d waiting or paused", waiting) }
        return L("Idle · everything is up to date")
    }

    private var serviceColor: Color {
        switch model.connection {
        case .connected: return Brand.green
        case .connecting: return Brand.yellow
        default: return Brand.red
        }
    }

    private var serviceTitle: String {
        switch model.connection {
        case .connected: return L("Sync service running")
        case .connecting(let n): return n > 1 ? L("Reconnecting…") : L("Connecting…")
        case .disconnected: return L("Sync service offline")
        case .idle: return L("Starting…")
        }
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.orange)
            Text(message).font(PDFont.text(12.5)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer(minLength: 8)
            IconButton(symbol: "xmark", help: L("Dismiss"), action: dismiss)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 560)
        .pdGlass(radius: 18, tint: Brand.orange)
    }
}

/// Standard page scaffold: scrollable, airy padding, max readable width.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// The PigmentDev rClone logo in the window's title bar, fixed above every page.
struct HeaderLogo: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { BrandLogoImage() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { BrandLogoImage() }
        }
    }
}

struct BrandLogoImage: View {
    @Environment(\.colorScheme) private var scheme
    var height: CGFloat = 26

    var body: some View {
        let name = scheme == .dark ? "logo-horizontal-dark" : "logo-horizontal"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(height: height)
                .padding(.leading, 14)
                .accessibilityLabel("PigmentDev rClone")
        } else {
            HStack(spacing: 6) {
                BrandMark(size: height)
                Text("PigmentDev rClone").font(PDFont.display(14, .black)).foregroundStyle(Theme.text)
            }
        }
    }
}

/// Smaller sidebar icons in a fixed-width column, with room before the title.
struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 18, alignment: .center)
            configuration.title
        }
    }
}
