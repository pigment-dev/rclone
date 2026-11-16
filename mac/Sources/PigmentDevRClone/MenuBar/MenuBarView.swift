import RCloneKit
import SwiftUI

/// The menu bar popover (shown by StatusItemController).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.menuIconState.running {
                let o = model.overall
                VStack(alignment: .leading, spacing: 6) {
                    // Until something needs uploading the total is 0 B: show "checking", not "0 B of 0 B".
                    // A folder-by-folder run: say which folder, not "X of X" for
                    // the bytes found so far (that read as done while it wasn't).
                    let part = model.runningJobs.count == 1 ? model.runningJobs.first?.progress?.partLine : nil
                    ProgressTrack(fraction: o.percent / 100, height: 6, indeterminate: o.totalBytes == 0 && part == nil)
                    HStack {
                        if let part {
                            Text(part).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(o.totalBytes == 0 ? L("Checking for changes…") : Fmt.bytes(o.bytes) + " " + L("of") + " " + Fmt.bytes(o.totalBytes))
                        }
                        Spacer()
                        if o.totalBytes > 0 || part != nil { Text(Fmt.percent(o.percent)) }
                    }
                    .font(PDFont.numbers(11))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            jobs
            if model.attentionCount > 0 { attention }
            footer
        }
        .padding(16)
        .frame(width: 380)
        // No focus ring on the first button when the popover opens.
        .focusEffectDisabled()
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("PigmentDev rClone").font(PDFont.display(15, .heavy)).foregroundStyle(Theme.text)
                OverallStatusText()
            }
            Spacer()
            IconButton(symbol: "macwindow", help: L("Open window")) { open(.dashboard) }
        }
    }

    @ViewBuilder private var jobs: some View {
        if model.jobs.isEmpty {
            VStack(spacing: 10) {
                Text(model.isConnected ? "No sync jobs yet" : "Waiting for the sync service")
                    .font(PDFont.text(13, .semibold)).foregroundStyle(Theme.textSecondary)
                if model.isConnected {
                    Button("Add a sync job…") { Self.closePopover(); router.addJob(firstRun: false) }.pdPrimary()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .pdGlass(radius: 18)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sortedJobs) { job in
                        JobRow(job: job, compact: true)
                            .padding(12)
                            .pdGlass(radius: 18, interactive: true)
                            .onTapGesture { open(.jobs, job: job.id) }
                    }
                }
                .pdGlassContainer(spacing: 8)
            }
            .scrollIndicators(.automatic)
            // A fixed height: the popover window doesn't give a ScrollView room on its own.
            // Up to three and a half rows show; more scroll.
            .frame(height: min(CGFloat(sortedJobs.count), 3.5) * 84)
        }
    }

    private var sortedJobs: [Job] {
        model.jobs.sorted { a, b in
            func rank(_ j: Job) -> Int { j.state == .running ? 0 : (j.state == .error || j.state == .needsBaseline) ? 1 : 2 }
            return rank(a) == rank(b) ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending : rank(a) < rank(b)
        }
    }

    private var attention: some View {
        Button { open(.actions) } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").foregroundStyle(Brand.orange)
                Text(model.attentionCount == 1 ? L("1 item needs attention") : L("%d items need attention", model.attentionCount))
                    .font(PDFont.text(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pdGlass(radius: 16, tint: Brand.orange, interactive: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.allPaused {
                Button { Task { await model.resumeAll() } } label: { Label("Resume all", systemImage: "play.fill") }
                    .pdPrimary()
            } else {
                Menu {
                    Button("For 1 hour") { Task { await model.pauseAll(.oneHour) } }
                    Button("Until tomorrow") { Task { await model.pauseAll(.untilTomorrow) } }
                    Button("Until I resume") { Task { await model.pauseAll(.untilResumed) } }
                } label: {
                    Label("Pause all", systemImage: "pause.fill")
                }
                .menuStyle(.button)
                .pdSecondary(large: false)
                .fixedSize()
                .disabled(!model.isConnected)
            }
            Spacer()
            Button { open(.settings) } label: { Image(systemName: "gearshape") }
                .pdSecondary(large: false)
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .pdSecondary(large: false)
                .help("Quit PigmentDev rClone")
        }
    }

    private func open(_ item: SidebarItem, job: String? = nil) {
        router.selection = item
        if let job { router.selectedJobID = job }
        Self.closePopover()
        router.openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        // The window may be closed (not just hidden): bring it back.
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true { w.makeKeyAndOrderFront(nil) }
    }

    /// Closes the menu bar popover when an action moves to another window.
    static func closePopover() {
        StatusItemController.shared.close()
    }
}
