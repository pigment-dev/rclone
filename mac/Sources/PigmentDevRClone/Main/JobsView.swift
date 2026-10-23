import AppKit
import RCloneKit
import SwiftUI

struct JobsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var search = ""

    var body: some View {
        Page {
            PageHeader(title: "Jobs", subtitle: "Each job keeps one folder on this Mac in sync with one place in the cloud.") {
                HStack(spacing: 10) {
                    SearchField(text: $search, prompt: "Filter jobs").frame(width: 200)
                    Button { router.addJob() } label: { Label("New job", systemImage: "plus") }
                        .pdPrimary()
                        .disabled(!model.isConnected)
                }
            }
            if filtered.isEmpty {
                GlassCard {
                    EmptyState(symbol: "arrow.triangle.2.circlepath", title: model.jobs.isEmpty ? "No sync jobs yet" : "No matching jobs",
                               message: model.jobs.isEmpty ? "Create a job to start syncing a folder." : "Try a different search.")
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(filtered) { job in
                        JobRow(job: job)
                            .padding(18)
                            .pdGlass(radius: 22, interactive: true)
                            .onTapGesture { router.selectedJobID = job.id }
                            .contextMenu { JobContextMenu(job: job) }
                    }
                }
                .pdGlassContainer(spacing: 12)
            }
        }
    }

    private var filtered: [Job] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let all = model.jobs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.localPath.localizedCaseInsensitiveContains(q) || $0.remotePath.localizedCaseInsensitiveContains(q) }
    }
}

struct JobContextMenu: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var body: some View {
        Button("Sync now") { Task { await model.run(job.id) } }
        Button("Dry run") { Task { await model.run(job.id, dryRun: true) } }
        if job.state == .paused { Button("Resume") { Task { await model.resume(job.id) } } }
        else { Button("Pause") { Task { await model.pause(job.id) } } }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: job.localPath) }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted).font(.system(size: 12))
            TextField(LocalizedStringKey(prompt), text: $text).textFieldStyle(.plain).font(PDFont.text(13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .pdGlass(in: Capsule())
    }
}

// MARK: - Detail

struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    var jobID: String

    @State private var draft = Job()
    @State private var loadedID: String?
    @State private var history: [RunSummary] = []
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var confirmResync = false
    @State private var section: DetailSection = .overview

    enum DetailSection: String, CaseIterable, Identifiable {
        case overview = "Overview", folders = "Folders", direction = "Direction", schedule = "Schedule",
             exclusions = "Exclusions", network = "Network", history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        let job = model.job(jobID) ?? draft
        Page {
            header(job)
            if let p = job.progress, job.state == .running { liveProgress(p) }
            GlassTabs(items: DetailSection.allCases, selection: $section, title: { $0.rawValue })
            sectionContent(job)
        }
        .safeAreaInset(edge: .bottom) { if isDirty { saveBar } }
        .onAppear { load(job) }
        .onChange(of: jobID) { _, _ in loadedID = nil; load(model.job(jobID) ?? Job()) }
        .task(id: jobID) { await loadHistory() }
        .confirmationDialog("Delete “\(job.name)”?", isPresented: $confirmDelete) {
            Button("Delete job", role: .destructive) {
                Task { await model.deleteJob(jobID); router.selectedJobID = nil }
            }
        } message: { Text("Files on this Mac and in the cloud are not touched.") }
        .confirmationDialog("Run the baseline sync?", isPresented: $confirmResync) {
            Button("Run baseline") { Task { await model.run(jobID, resync: true) } }
        } message: {
            Text("A baseline compares both sides from scratch and makes them identical. Files present on only one side are copied to the other. Nothing is deleted.")
        }
    }

    private var isDirty: Bool {
        guard let live = model.job(jobID), loadedID == jobID else { return false }
        return JobSpec(live) != JobSpec(draft)
    }

    private func load(_ job: Job) {
        guard loadedID != jobID, !job.id.isEmpty else { return }
        draft = job
        loadedID = jobID
    }

    private func loadHistory() async {
        guard let client = model.client else { return }
        history = (try? await client.call("jobs.history", HistoryParams(id: jobID, limit: 20), as: HistoryResult.self).runs) ?? []
    }

    // MARK: Header

    private func header(_ job: Job) -> some View {
        let account = model.account(job.accountId)
        let status = job.status ?? JobStatus()
        return VStack(alignment: .leading, spacing: 18) {
            Button { router.selectedJobID = nil } label: { Label("All jobs", systemImage: "chevron.backward") }
                .buttonStyle(.plain)
                .font(PDFont.text(12.5, .semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .center, spacing: 16) {
                ProviderIcon(id: account?.provider ?? "", size: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.name).font(PDFont.display(28, .black)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 8) {
                        StatusBadge(label: status.label)
                        if let d = status.label.detail { Text(d).font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted).lineLimit(1) }
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                switch status.state {
                case .running:
                    Button { Task { await model.cancel(jobID) } } label: { Label("Stop", systemImage: "stop.fill") }.pdSecondary()
                    Button { Task { await model.pause(jobID) } } label: { Label("Pause", systemImage: "pause.fill") }.pdSecondary()
                case .paused:
                    Button { Task { await model.resume(jobID) } } label: { Label("Resume", systemImage: "play.fill") }.pdPrimary()
                case .needsBaseline:
                    Button { confirmResync = true } label: { Label("Run baseline", systemImage: "arrow.left.arrow.right") }.pdPrimary()
                default:
                    Button { Task { await model.run(jobID) } } label: { Label("Sync now", systemImage: "arrow.clockwise") }.pdPrimary()
                }
                Button { Task { await model.run(jobID, dryRun: true) } } label: { Label("Dry run", systemImage: "eye") }.pdSecondary()
                if job.direction == .twoWay && status.state != .needsBaseline {
                    Button { confirmResync = true } label: { Label("Resync baseline", systemImage: "arrow.left.arrow.right") }.pdSecondary()
                }
                if status.state != .paused && status.state != .running {
                    Button { Task { await model.pause(jobID) } } label: { Label("Pause", systemImage: "pause") }.pdSecondary()
                }
                Spacer()
                Menu {
                    Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: job.localPath) }
                    Button("Open in the cloud") { openRemote(job, account) }
                    Button("Copy remote path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString((account?.remote ?? "") + ":" + job.remotePath, forType: .string)
                    }
                    Button("View logs") { router.logJobFilter = jobID; router.show(.logs) }
                    Divider()
                    Button("Delete job…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .pdSecondary()
                .fixedSize()
            }
        }
    }

    private func openRemote(_ job: Job, _ account: Account?) {
        let path = job.remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let url: String?
        switch account?.provider {
        case "drive": url = "https://drive.google.com/drive/my-drive"
        case "onedrive": url = "https://onedrive.live.com/"
        case "dropbox": url = "https://www.dropbox.com/home/" + path
        case "box": url = "https://app.box.com/folder/0"
        case "pcloud": url = "https://my.pcloud.com/"
        case "mega": url = "https://mega.nz/fm"
        case "protondrive": url = "https://drive.proton.me/"
        case "local": NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/" + job.remotePath); return
        default: url = nil
        }
        if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: Live progress

    private func liveProgress(_ p: SyncProgress) -> some View {
        GlassCard(tint: Brand.orange) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Transferring", color: Brand.orange)
                    Spacer()
                    Text(Fmt.percent(p.percent)).font(PDFont.display(20, .heavy)).foregroundStyle(Theme.text)
                }
                JobProgressBlock(progress: p)
                if p.totalChecks > 0 {
                    Text("Checked \(Fmt.count(p.checks)) of \(Fmt.count(p.totalChecks)) files" + (p.errors > 0 ? " · \(p.errors) errors" : ""))
                        .font(PDFont.numbers(11.5)).foregroundStyle(Theme.textMuted)
                }
                if !p.transferring.isEmpty {
                    Divider().opacity(0.4)
                    VStack(spacing: 10) {
                        ForEach(Array(p.transferring.enumerated()), id: \.offset) { _, t in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "doc.fill").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                                    Text(t.name).font(PDFont.text(12, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.bytes(t.bytes) + " / " + Fmt.bytes(t.size)).font(PDFont.numbers(11)).foregroundStyle(Theme.textMuted)
                                    Text(Fmt.speed(t.speed)).font(PDFont.numbers(11)).foregroundStyle(Theme.textSecondary).frame(minWidth: 70, alignment: .trailing)
                                }
                                ProgressTrack(fraction: t.percent / 100, tint: Brand.cobalt, height: 4)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private func sectionContent(_ job: Job) -> some View {
        switch section {
        case .overview: overview(job)
        case .folders:
            GlassCard {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledField("Name") { TextField("Job name", text: $draft.name).textFieldStyle(.roundedBorder) }
                    LocalFolderEditor(job: $draft)
                    Divider().opacity(0.4)
                    SectionLabel("Cloud folder")
                    RemoteBrowser(accountID: draft.accountId, path: $draft.remotePath).frame(height: 300)
                }
            }
        case .direction: GlassCard { DirectionEditor(job: $draft) }
        case .schedule: GlassCard { ScheduleEditor(triggers: $draft.triggers) }
        case .exclusions: GlassCard { ExclusionsEditor(job: $draft, jobID: jobID) }
        case .network: GlassCard { NetworkEditor(job: $draft) }
        case .history: historyView
        }
    }

    private func overview(_ job: Job) -> some View {
        let account = model.account(job.accountId)
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                InfoTile(title: "This Mac", value: Fmt.path(job.localPath), symbol: "laptopcomputer")
                InfoTile(title: "Cloud", value: (account?.name ?? "—") + ": /" + job.remotePath, symbol: "cloud")
            }
            HStack(spacing: 14) {
                InfoTile(title: "Direction", value: job.direction.title, symbol: job.direction.symbol)
                InfoTile(title: "Deletions", value: job.deletePolicy.title, symbol: "trash")
                InfoTile(title: "Conflicts", value: job.conflictPolicy.title, symbol: "arrow.triangle.branch")
            }
            HStack(spacing: 14) {
                InfoTile(title: "Schedule", value: ScheduleEditor.summary(job.triggers), symbol: "calendar.badge.clock")
                InfoTile(title: "Excluded", value: job.filters.presets.compactMap { FilterPreset.named($0)?.title }.joined(separator: ", ").ifEmpty("Nothing"), symbol: "line.3.horizontal.decrease.circle")
            }
            if let last = job.status?.lastRun {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Last run")
                        RunRow(run: last)
                    }
                }
            }
        }
        .pdGlassContainer(spacing: 14)
    }

    private var historyView: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Run history")
                    Spacer()
                    Button { Task { await loadHistory() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
                if history.isEmpty { Text("No runs yet").font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted) }
                ForEach(history) { run in
                    RunRow(run: run)
                    if run.id != history.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            let issues = JobValidator.allIssues(draft)
            Image(systemName: issues.isEmpty ? "pencil.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issues.isEmpty ? Brand.orange : Brand.red)
            Text(issues.first?.message ?? L("You have unsaved changes"))
                .font(PDFont.text(13, .medium)).foregroundStyle(Theme.text)
            Spacer()
            Button("Revert") { if let j = model.job(jobID) { draft = j } }.pdSecondary(large: false)
            Button(saving ? "Saving…" : "Save changes") {
                saving = true
                Task {
                    do { draft = try await model.updateJob(draft) } catch { model.report(error) }
                    saving = false
                }
            }
            .pdPrimary()
            .disabled(saving || !issues.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .pdGlass(radius: 20)
        .padding(.horizontal, 32).padding(.bottom, 16)
        .frame(maxWidth: 1100)
    }
}

struct RunRow: View {
    var run: RunSummary
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(run.ok ? Brand.green : Brand.red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Fmt.clock(run.startedAt)).font(PDFont.text(12.5, .semibold)).foregroundStyle(Theme.text)
                    if run.dryRun { Pill(text: L("Dry run"), color: Brand.cobalt) }
                }
                if let e = run.error { Text(e).font(PDFont.text(11.5)).foregroundStyle(Brand.red).lineLimit(2) }
            }
            Spacer()
            Group {
                Text("\(Fmt.count(run.files)) files")
                Text(Fmt.bytes(run.bytes))
                if run.deletes > 0 { Text("\(run.deletes) deleted") }
                if run.conflicts > 0 { Text("\(run.conflicts) conflicts").foregroundStyle(Brand.orange) }
            }
            .font(PDFont.numbers(11.5))
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

struct InfoTile: View {
    var title: String
    var value: String
    var symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.orange).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(title)
                Text(value).font(PDFont.text(13, .medium)).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdGlass(radius: 20)
    }
}

struct LabeledField<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            content
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
