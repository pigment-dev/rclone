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
        .safeAreaInset(edge: .bottom) { ConnectionFooter().padding(12) }
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
