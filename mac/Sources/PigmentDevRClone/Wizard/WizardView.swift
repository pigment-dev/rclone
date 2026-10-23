import RCloneKit
import SwiftUI

struct WizardView: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var firstRun: Bool
    @State private var job = Job.draft()
    @State private var index = 0
    @State private var created: Job?
    @State private var createdCount = 0
    /// Folders beyond the first; each becomes its own job with the same settings.
    @State private var extraFolders: [String] = []
    @State private var busy = false
    @State private var error: String?
    @State private var showIssues = false
    @State private var preview = PreviewState()

    private var steps: [WizardStep] { WizardStep.flow(firstRun: firstRun) }
    private var step: WizardStep { steps[min(index, steps.count - 1)] }
    private var issues: [ValidationIssue] { JobValidator.issues(for: step, job: job) }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(L("Step %d of %d", index + 1, steps.count), color: Brand.orange)
                        Text(LocalizedStringKey(headline)).font(PDFont.display(26, .black)).foregroundStyle(Theme.text)
                        Text(LocalizedStringKey(subhead)).font(PDFont.text(13.5)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    if showIssues, !issues.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(issues) { i in
                                Label(i.message, systemImage: "exclamationmark.circle.fill").font(PDFont.text(12.5)).foregroundStyle(Brand.red)
                            }
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(PDFont.text(12.5)).foregroundStyle(Brand.red)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer.padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: 820, height: 680)
        .background(Backdrop())
        .onAppear {
            job = Job.draft(defaults: model.settings?.defaults)
            if model.accounts.count == 1 { job.accountId = model.accounts[0].id }
            // Screenshot hook: PDRCLONE_WIZARD_STEP=<step name> jumps to a step with a filled-in draft.
            if let name = ProcessInfo.processInfo.environment["PDRCLONE_WIZARD_STEP"],
               let i = steps.firstIndex(where: { "\($0)" == name }) {
                job.name = "Projects"
                job.localPath = NSHomeDirectory() + "/Projects"
                job.remotePath = "Backups/Projects"
                if let extra = ProcessInfo.processInfo.environment["PDRCLONE_WIZARD_EXTRA"] { extraFolders = extra.split(separator: ":").map { NSHomeDirectory() + "/" + $0 } }
                if job.accountId.isEmpty, let a = model.accounts.first { job.accountId = a.id }
                index = i
            }
        }
    }

    // MARK: Chrome

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                let done = i < index, current = i == index
                HStack(spacing: 6) {
                    Image(systemName: done ? "checkmark" : s.symbol)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(current ? Color.white : done ? Brand.orange : Theme.textMuted)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(current ? Brand.orange : done ? Brand.orange.opacity(0.14) : Theme.track))
                    if current {
                        Text(LocalizedStringKey(s.title)).font(PDFont.text(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                    }
                }
                .padding(.trailing, current ? 6 : 0)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.title + (done ? ", " + L("done") : current ? ", " + L("current step") : ""))
                if i < steps.count - 1 {
                    Capsule().fill(i < index ? Brand.orange.opacity(0.5) : Theme.hairline.opacity(0.6)).frame(height: 2).frame(maxWidth: 30)
                }
            }
        }
        .padding(8)
        .pdGlass(in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .done {
                Button("Cancel") { finish(onboard: firstRun) }.pdSecondary()
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if index > 0 && step != .done {
                Button { go(-1) } label: { Label("Back", systemImage: "chevron.backward") }.pdSecondary()
            }
            primaryButton
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .preview:
            Button { Task { await create() } } label: {
                if busy { ProgressView().controlSize(.small) } else { Label("Create job", systemImage: "checkmark") }
            }
            .pdPrimary().keyboardShortcut(.defaultAction).disabled(busy)
        case .done:
            HStack {
                Button("Close") { finish(onboard: true) }.pdSecondary()
                Button {
                    if createdCount > 1 {
                        let ids = model.jobs.filter { j in ([job.localPath] + extraFolders).contains(j.localPath) && j.accountId == job.accountId }.map { ($0.id, $0.direction) }
                        Task { for (id, dir) in ids { await model.run(id, dryRun: false, resync: dir == .twoWay) } }
                    } else if let c = created { Task { await model.run(c.id, dryRun: false, resync: c.direction == .twoWay) } }
                    finish(onboard: true)
                    if let c = created { router.show(.jobs, job: c.id) }
                } label: { Label(created?.direction == .twoWay ? (createdCount > 1 ? "Run baselines now" : "Run baseline now") : (createdCount > 1 ? "Sync all now" : "Sync now"), systemImage: "arrow.clockwise") }
                .pdPrimary().keyboardShortcut(.defaultAction)
            }
        default:
            Button { go(1) } label: { Label(step == .welcome ? "Get started" : "Continue", systemImage: "chevron.forward") }
                .pdPrimary().keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ delta: Int) {
        if delta > 0 && !issues.isEmpty { showIssues = true; return }
        showIssues = false
        error = nil
        if delta > 0, steps[index] == .network || (steps[index + 1] == .preview) {
            if job.name.isEmpty { job.name = JobValidator.suggestedName(localPath: job.localPath, accountName: model.account(job.accountId)?.name) }
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) {
            index = max(0, min(steps.count - 1, index + delta))
        }
    }

    private func create() async {
        let all = JobValidator.allIssues(job)
        if let first = all.first { error = first.message; return }
        busy = true
        defer { busy = false }
        do {
            if extraFolders.isEmpty {
                created = try await model.createJob(job)
                createdCount = 1
            } else {
                var first: Job?
                var count = 0
                for j in jobs {
                    let c = try await model.createJob(j)
                    if first == nil { first = c }
                    count += 1
                }
                created = first
                createdCount = count
            }
            withAnimation { index = steps.count - 1 }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Multi-folder plan: each local folder syncs into its own subfolder of the chosen remote folder.
    private var plan: [(local: String, remote: String)] {
        let base = job.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var used: Set<String> = []
        return ([job.localPath] + extraFolders).filter { !$0.isEmpty }.map { local in
            var name = (local as NSString).lastPathComponent
            if used.contains(name) {
                let parent = ((local as NSString).deletingLastPathComponent as NSString).lastPathComponent
                name = "\(parent)-\(name)"
            }
            used.insert(name)
            return (local, base.isEmpty ? name : base + "/" + name)
        }
    }

    private var jobs: [Job] {
        plan.map { item in
            var j = job
            j.localPath = item.local
            j.remotePath = item.remote
            j.name = JobValidator.suggestedName(localPath: item.local, accountName: model.account(job.accountId)?.name)
            return j
        }
    }

    private func finish(onboard: Bool) {
        if onboard { prefs.onboarded = true }
        router.showWizard = false
        dismiss()
    }

    // MARK: Copy

    private var headline: String {
        switch step {
        case .welcome: return "Sync folders, not headaches."
        case .permissions: return "A few permissions"
        case .account: return "Where should your files go?"
        case .local: return "Pick folders on this Mac"
        case .remote: return "Pick a folder in the cloud"
        case .direction: return "How should it sync?"
        case .schedule: return "When should it sync?"
        case .exclusions: return "What should it skip?"
        case .network: return "Network & power rules"
        case .preview: return "Here's what will happen"
        case .done: return "You're all set"
        }
    }

    private var subhead: String {
        switch step {
        case .welcome: return "PigmentDev rClone keeps folders on this Mac in sync with Google Drive, OneDrive, Dropbox, S3, SFTP and more — quietly, with a tiny memory footprint, and without copying your .git folders."
        case .permissions: return "All optional. You can change these later in System Settings."
        case .account: return "Choose a connected account, or add a new one."
        case .local: return "Each folder and everything inside it (minus exclusions) will sync. You can add several."
        case .remote: return "Browse your storage and choose — or create — the destination folder."
        case .direction: return "Choose the direction, what happens to deletions, and how conflicts are handled."
        case .schedule: return "Combine as many triggers as you like."
        case .exclusions: return "Sensible defaults are already on. Developers: your repos stay lean."
        case .network: return "Keep syncing polite on hotspots, batteries and busy networks."
        case .preview: return "A dry run of the first sync. Nothing has been changed yet."
        case .done: return "Your job is ready. Progress shows in the menu bar."
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .account: AccountStep(job: $job)
        case .local: LocalFolderEditor(job: $job, extraFolders: $extraFolders)
        case .remote:
            VStack(alignment: .leading, spacing: 10) {
                RemoteBrowser(accountID: job.accountId, path: $job.remotePath).frame(height: extraFolders.isEmpty ? 360 : 300)
                if !extraFolders.isEmpty {
                    Label(L("Each folder goes into its own subfolder here: %@", plan.map { "/" + Fmt.remote($0.remote) }.joined(separator: ", ")), systemImage: "folder.badge.gearshape")
                        .font(PDFont.text(12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .direction: DirectionEditor(job: $job)
        case .schedule: ScheduleEditor(triggers: $job.triggers)
        case .exclusions: ExclusionsEditor(job: $job, jobID: nil)
        case .network: NetworkEditor(job: $job)
        case .preview:
            VStack(alignment: .leading, spacing: 16) {
                if extraFolders.isEmpty {
                    LabeledField("Job name") { TextField("Name", text: $job.name).textFieldStyle(.roundedBorder).font(PDFont.text(14)) }
                } else {
                    LabeledField(L("%d jobs will be created", plan.count)) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan, id: \.local) { item in
                                Text("\(Fmt.path(item.local))  →  /\(Fmt.remote(item.remote))").font(PDFont.mono(11.5, .medium)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Text("The preview below is for the first folder. The others use the same settings.")
                        .font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                }
                PreviewPanel(job: extraFolders.isEmpty ? job : jobs.first ?? job, state: $preview)
            }
        case .done:
            VStack(spacing: 12) {
                DoneStep(job: created ?? job)
                if createdCount > 1 {
                    Text(L("%d jobs were created, one per folder. They appear in Jobs.", createdCount))
                        .font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                FeatureTile(symbol: "memorychip", title: "Light", text: "Runs as a small background service. The window can stay closed.")
                FeatureTile(symbol: "line.3.horizontal.decrease.circle", title: "Smart exclusions", text: ".git, node_modules, .claude and OS junk stay local.")
                FeatureTile(symbol: "arrow.up.arrow.down", title: "One-way or two-way", text: "Backups, mirrors and true sync, with conflict handling.")
            }
            HStack(spacing: 14) {
                FeatureTile(symbol: "wifi", title: "Network aware", text: "Pause on hotspots, batteries or specific Wi-Fi networks.")
                FeatureTile(symbol: "bell.badge", title: "Action Center", text: "Conflicts and errors wait for you instead of failing silently.")
                FeatureTile(symbol: "lock.open", title: "Open source", text: "MIT licensed, powered by rclone. No telemetry.")
            }
        }
        .pdGlassContainer(spacing: 14)
    }
}

struct FeatureTile: View {
    var symbol: String
    var title: String
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.orange)
            Text(LocalizedStringKey(title)).font(PDFont.display(15, .heavy)).foregroundStyle(Theme.text)
            Text(LocalizedStringKey(text)).font(PDFont.text(12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .pdGlass(radius: 20)
    }
}

struct PermissionsStep: View {
    @State private var perms = Permissions.shared

    var body: some View {
        VStack(spacing: 12) {
            PermissionRow(symbol: "bell.badge.fill", title: "Notifications", text: "Tell you about conflicts, errors and finished syncs.",
                          status: perms.notifications, actionTitle: "Allow") { perms.requestNotifications() }
            PermissionRow(symbol: "externaldrive.fill.badge.checkmark", title: "Full Disk Access", text: "Only needed to sync protected folders such as Mail or other apps' data. Most folders work without it.",
                          status: perms.fullDiskAccess, actionTitle: "Open Settings") { perms.openFullDiskAccess() }
            PermissionRow(symbol: "location.fill", title: "Location (for Wi-Fi names)", text: "macOS only reveals the Wi-Fi network name to apps with Location access. Needed for “only on Home Wi-Fi” rules. Your location is never read or stored.",
                          status: perms.location, actionTitle: "Allow") { perms.requestLocation() }
        }
        .pdGlassContainer(spacing: 12)
        .onAppear { perms.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in perms.refresh() }
    }
}

struct PermissionRow: View {
    var symbol: String
    var title: String
    var text: String
    var status: Permissions.Status
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.orange)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Brand.orange.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(PDFont.text(14, .semibold)).foregroundStyle(Theme.text)
                Text(LocalizedStringKey(text)).font(PDFont.text(12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            switch status {
            case .granted: Pill(text: L("Allowed"), symbol: "checkmark", color: Brand.green)
            case .denied:
                VStack(alignment: .trailing, spacing: 4) {
                    Pill(text: L("Off"), symbol: "xmark", color: Theme.textMuted)
                    Button(actionTitle == "Allow" ? "Open Settings" : actionTitle, action: action).buttonStyle(.link).font(PDFont.text(11.5, .semibold))
                }
            case .unknown: Button(LocalizedStringKey(actionTitle), action: action).pdSecondary(large: false)
            }
        }
        .padding(16)
        .pdGlass(radius: 20)
    }
}

struct DoneStep: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(Brand.green)
                .symbolEffect(.bounce, value: job.id)
            Text(job.name).font(PDFont.display(20, .heavy)).foregroundStyle(Theme.text)
            HStack(spacing: 12) {
                InfoTile(title: "This Mac", value: Fmt.path(job.localPath), symbol: "laptopcomputer")
                InfoTile(title: "Cloud", value: (model.account(job.accountId)?.name ?? "") + ": /" + Fmt.remote(job.remotePath), symbol: "cloud")
            }
            InfoTile(title: "Schedule", value: ScheduleEditor.summary(job.triggers), symbol: "calendar.badge.clock")
            if job.direction == .twoWay {
                Text("Two-way jobs begin with a baseline: both sides are compared and merged once, without deleting anything.")
                    .font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

struct PreviewState: Equatable {
    var result: PreviewResult?
    var loading = false
    var error: String?
    var spec: JobSpec?
}

struct PreviewPanel: View {
    @Environment(AppModel.self) private var model
    var job: Job
    @Binding var state: PreviewState
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Comparing both sides… large folders can take a minute.").font(PDFont.text(13)).foregroundStyle(Theme.textSecondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).pdGlass(radius: 20)
            } else if let e = state.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(PDFont.text(12.5)).foregroundStyle(Brand.red)
                    Button("Try again") { Task { await run() } }.pdSecondary(large: false)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).pdGlass(radius: 20)
            } else if let r = state.result {
                HStack(spacing: 12) {
                    StatTile(symbol: "plus.circle.fill", value: Fmt.count(r.adds), label: "New", tint: Brand.green)
                    StatTile(symbol: "arrow.triangle.2.circlepath", value: Fmt.count(r.updates), label: "Updated", tint: Brand.cobalt)
                    StatTile(symbol: "trash.fill", value: Fmt.count(r.deletes), label: "Deleted", tint: r.deletes > 0 ? Brand.red : Theme.textMuted)
                    StatTile(symbol: "minus.circle.fill", value: Fmt.count(r.excluded), label: "Skipped", tint: Brand.orange)
                    StatTile(symbol: "externaldrive.fill", value: Fmt.bytes(r.bytes), label: "To transfer", tint: Theme.textSecondary)
                }
                .pdGlassContainer(spacing: 12)
                if r.deletes > 0, job.safety.maxDeletePercent > 0 {
                    Label("Deletions are guarded: a run that would delete more than \(job.safety.maxDeletePercent)% of files stops and asks first.", systemImage: "shield.lefthalf.filled")
                        .font(PDFont.text(12)).foregroundStyle(Theme.textSecondary)
                }
                Picker("List", selection: $tab) {
                    Text("New (\(r.sample.adds.count))").tag(0)
                    Text("Updated (\(r.sample.updates.count))").tag(1)
                    Text("Deleted (\(r.sample.deletes.count))").tag(2)
                    Text("Skipped (\(r.sample.excluded.count))").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
                sampleList(r)
            }
        }
        .task(id: JobSpec(job)) {
            if state.spec != JobSpec(job) || state.result == nil { await run() }
        }
    }

    @ViewBuilder private func sampleList(_ r: PreviewResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows: [(String, String?)] = {
                switch tab {
                case 0: return r.sample.adds.map { ($0, nil) }
                case 1: return r.sample.updates.map { ($0, nil) }
                case 2: return r.sample.deletes.map { ($0, nil) }
                default: return r.sample.excluded.map { ($0.path, $0.rule) }
                }
            }()
            if rows.isEmpty {
                Text("Nothing here").font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted).padding(14)
            }
            ForEach(Array(rows.prefix(80).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Image(systemName: tab == 3 ? "minus.circle" : "doc").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                    Text(row.0).font(PDFont.mono(11.5, .regular)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let rule = row.1 {
                        Text(rule).font(PDFont.mono(10.5, .medium)).foregroundStyle(Brand.orange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Brand.orange.opacity(0.1)))
                            .help(L("Skipped because it matches this rule"))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdGlass(radius: 18)
    }

    private func run() async {
        guard let client = model.client else { return }
        let spec = JobSpec(job)
        state = PreviewState(result: nil, loading: true, error: nil, spec: spec)
        do {
            var result = try await client.call("jobs.preview", PreviewParams.job(spec), as: PreviewResult.self, timeout: 125)
            if result.isPending, let runId = result.runId {
                result = try await waitForPreview(runId: runId)
            }
            state = PreviewState(result: result, loading: false, error: nil, spec: spec)
        } catch {
            state = PreviewState(result: nil, loading: false, error: error.localizedDescription, spec: spec)
        }
    }

    /// Async variant: the daemon returns {runId} and later emits `job.preview`.
    private func waitForPreview(runId: String) async throws -> PreviewResult {
        try await withCheckedThrowingContinuation { cont in
            var done = false
            model.onPreview = { note in
                guard !done, note.runId == runId || note.runId == nil, let r = note.result else { return }
                done = true
                model.onPreview = nil
                cont.resume(returning: r)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                guard !done else { return }
                done = true
                model.onPreview = nil
                cont.resume(throwing: ClientError.timeout("jobs.preview"))
            }
        }
    }
}
