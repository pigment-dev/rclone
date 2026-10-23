import AppKit
import RCloneKit
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    enum Range: String, CaseIterable, Identifiable {
        case hour = "Last hour", day = "Last 24 hours", week = "Last 7 days", all = "All time"
        var id: String { rawValue }
        var since: Date? {
            switch self {
            case .hour: return Date().addingTimeInterval(-3600)
            case .day: return Date().addingTimeInterval(-86400)
            case .week: return Date().addingTimeInterval(-7 * 86400)
            case .all: return nil
            }
        }
    }

    @State private var lines: [LogLine] = []
    @State private var level: LogLine.Level = .info
    @State private var jobID: String = ""
    @State private var search = ""
    @State private var range: Range = .day
    @State private var live = false
    @State private var loading = false
    @State private var showExplain = false
    @State private var selection = Set<LogLine.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Logs", subtitle: "Every transfer, skip and error — searchable.") {
                HStack(spacing: 8) {
                    Button { showExplain = true } label: { Label("Why didn't this file sync?", systemImage: "questionmark.circle") }
                        .pdSecondary()
                        .popover(isPresented: $showExplain, arrowEdge: .bottom) { ExplainPopover(initialJob: jobID).environment(model) }
                    Menu {
                        Button("Export as text…") { export(format: "text") }
                        Button("Export as JSON…") { export(format: "json") }
                        Divider()
                        Button("Diagnostics bundle…") { diagnostics() }
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .menuStyle(.button).pdSecondary().fixedSize()
                }
            }
            filters
            table
        }
        .padding(.horizontal, 32).padding(.vertical, 28)
        .task(id: query) { await load() }
        .onAppear { if let j = router.logJobFilter { jobID = j; router.logJobFilter = nil } }
        .onChange(of: live) { _, on in Task { await model.setLiveTail(on) } }
        .onDisappear { if live { Task { await model.setLiveTail(false) } } }
    }

    private var query: String { "\(level.rawValue)|\(jobID)|\(search)|\(range.rawValue)" }

    private var filters: some View {
        HStack(spacing: 10) {
            SearchField(text: $search, prompt: "Search messages and paths").frame(maxWidth: 280)
            Picker("Level", selection: $level) {
                ForEach(LogLine.Level.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized + "+")).tag($0) }
            }
            .frame(width: 120)
            Picker("Job", selection: $jobID) {
                Text("All jobs").tag("")
                ForEach(model.jobs) { Text($0.name).tag($0.id) }
            }
            .frame(width: 180)
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .frame(width: 150)
            Spacer()
            Toggle(isOn: $live) { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
                .toggleStyle(.button)
                .tint(Brand.orange)
            if loading { ProgressView().controlSize(.small) }
        }
        .labelsHidden()
    }

    private var shown: [LogLine] {
        var all = lines
        if live {
            let since = range.since
            let extra = model.liveLog.reversed().filter { l in
                l.level >= level && (jobID.isEmpty || l.jobId == jobID) &&
                    (search.isEmpty || l.msg.localizedCaseInsensitiveContains(search) || (l.path ?? "").localizedCaseInsensitiveContains(search)) &&
                    (since == nil || (RFC3339.date(l.ts) ?? Date()) >= since!)
            }
            let known = Set(all.map(\.id))
            all = extra.filter { !known.contains($0.id) } + all
        }
        return all
    }

    private var table: some View {
        Table(shown, selection: $selection) {
            TableColumn("Time") { l in Text(Fmt.clock(l.ts)).font(PDFont.numbers(11.5)).foregroundStyle(Theme.textSecondary) }
                .width(min: 70, ideal: 110, max: 140)
            TableColumn("Level") { l in LevelBadge(level: l.level) }
                .width(min: 60, ideal: 70, max: 80)
            TableColumn("Job") { l in Text(model.job(l.jobId)?.name ?? "—").font(PDFont.text(12)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                .width(min: 80, ideal: 140, max: 220)
            TableColumn("Message") { l in
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.msg).font(PDFont.text(12.5)).foregroundStyle(Theme.text).lineLimit(2)
                    if let p = l.path { Text(p).font(PDFont.mono(10.5, .regular)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle) }
                }
            }
        }
        .contextMenu(forSelectionType: LogLine.ID.self) { ids in
            Button("Copy") {
                let text = shown.filter { ids.contains($0.id) }.map { "\($0.ts) [\($0.level.rawValue)] \($0.msg)" + ($0.path.map { " \($0)" } ?? "") }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .scrollContentBackground(.hidden)
        .padding(6)
        .pdGlass(radius: 20)
        .overlay {
            if shown.isEmpty && !loading {
                EmptyState(symbol: "text.alignleft", title: "No log lines", message: "Nothing matches these filters yet.")
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        loading = true
        defer { loading = false }
        let p = LogQueryParams(jobId: jobID.isEmpty ? nil : jobID, level: level.rawValue, search: search.isEmpty ? nil : search,
                               since: range.since.map(RFC3339.string), limit: 500)
        do { lines = try await client.call("log.query", p, as: LogQueryResult.self).lines } catch { model.report(error) }
    }

    private func export(format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pdrclone-logs." + (format == "json" ? "json" : "log")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.perform { _ = try await $0.call("log.export", LogExportParams(jobId: jobID.isEmpty ? nil : jobID, format: format, dest: url.path), as: PathResult.self, timeout: 120) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func diagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pdrclone-diagnostics.zip"
        panel.message = L("Secrets are redacted. Attach this file to a GitHub issue.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.perform { _ = try await $0.call("diag.bundle", DestParams(dest: url.path), as: PathResult.self, timeout: 120) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct LevelBadge: View {
    var level: LogLine.Level
    var body: some View {
        Text(level.rawValue.uppercased())
            .font(PDFont.mono(9.5))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
    var color: Color {
        switch level {
        case .debug: return Theme.textMuted
        case .info: return Brand.cobalt
        case .notice: return Brand.green
        case .warn: return Color(light: 0xC98A00, dark: 0xFFC72C)
        case .error: return Brand.red
        }
    }
}

/// "Why didn't this file sync?" — path → jobs.explain.
struct ExplainPopover: View {
    @Environment(AppModel.self) private var model
    var initialJob: String
    @State private var jobID = ""
    @State private var path = ""
    @State private var result: ExplainResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why didn't this file sync?").font(PDFont.display(16, .heavy)).foregroundStyle(Theme.text)
            Picker("Job", selection: $jobID) {
                ForEach(model.jobs) { Text($0.name).tag($0.id) }
            }
            HStack {
                TextField("Path or file name inside the job's folder", text: $path).textFieldStyle(.roundedBorder).onSubmit { Task { await ask() } }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.showsHiddenFiles = true
                    if let j = model.job(jobID) { panel.directoryURL = URL(fileURLWithPath: j.localPath) }
                    if panel.runModal() == .OK, let u = panel.url { path = u.path }
                }
            }
            Button("Explain") { Task { await ask() } }.pdPrimary().disabled(path.isEmpty || jobID.isEmpty)
            if let r = result {
                Label(r.included ? L("This file is included — it syncs on the next run.") : L("This file is excluded."),
                      systemImage: r.included ? "checkmark.circle.fill" : "minus.circle.fill")
                    .foregroundStyle(r.included ? Brand.green : Brand.orange)
                    .font(PDFont.text(13, .semibold))
                if let rule = r.rule {
                    HStack { Text("Matching rule:").font(PDFont.text(12)); Text(rule).font(PDFont.mono(12, .medium)) }.foregroundStyle(Theme.textSecondary)
                }
            }
            if let error { Text(error).font(PDFont.text(12)).foregroundStyle(Brand.red) }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { jobID = initialJob.isEmpty ? (model.jobs.first?.id ?? "") : initialJob }
    }

    private func ask() async {
        guard let client = model.client, let job = model.job(jobID) else { return }
        var rel = path
        if rel.hasPrefix(job.localPath) { rel = String(rel.dropFirst(job.localPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        error = nil
        do { result = try await client.call("jobs.explain", ExplainParams(id: jobID, path: rel), as: ExplainResult.self) }
        catch { self.error = error.localizedDescription; result = FilterEvaluator.explain(rel, filters: job.filters) }
    }
}
