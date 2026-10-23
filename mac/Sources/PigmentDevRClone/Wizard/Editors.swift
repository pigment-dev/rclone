import AppKit
import RCloneKit
import SwiftUI
import UniformTypeIdentifiers

// Editors shared by the wizard steps and the editable Job detail sections.

// MARK: - Local folder

struct LocalFolderEditor: View {
    @Binding var job: Job
    /// Wizard only: more folders that get their own job with the same settings.
    var extraFolders: Binding<[String]>? = nil

    private var all: [String] { ([job.localPath] + (extraFolders?.wrappedValue ?? [])).filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(extraFolders == nil ? "Folder on this Mac" : "Folders on this Mac")
            if all.isEmpty {
                row(path: "", index: 0)
            } else {
                ForEach(Array(all.enumerated()), id: \.element) { i, path in row(path: path, index: i) }
            }
            if extraFolders != nil, !all.isEmpty {
                HStack {
                    Button { choose(adding: true) } label: { Label("Add another folder…", systemImage: "plus") }.pdSecondary(large: false)
                    Spacer()
                    if all.count > 1 {
                        Text(L("%d folders · each one becomes its own job with these settings", all.count))
                            .font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.hasDirectoryPath else { return }
                    DispatchQueue.main.async { add([url.path]) }
                }
            }
            return true
        }
    }

    private func row(path: String, index: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: path.isEmpty ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Brand.orange)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.orange.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(path.isEmpty ? L("No folder chosen") : (path as NSString).lastPathComponent)
                    .font(PDFont.text(15, .semibold)).foregroundStyle(Theme.text)
                Text(path.isEmpty ? L("Choose the folder you want to keep in sync.") : Fmt.path(path))
                    .font(PDFont.text(12)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if path.isEmpty {
                Button("Choose folder…") { choose(adding: false) }.pdSecondary()
            } else if extraFolders != nil && all.count > 1 {
                IconButton(symbol: "minus", help: L("Remove")) { remove(at: index) }
            } else {
                Button("Change…") { choose(adding: false) }.pdSecondary()
            }
        }
        .padding(16)
        .pdGlass(radius: 20)
    }

    private func add(_ paths: [String]) {
        guard let extra = extraFolders else { if let p = paths.first { job.localPath = p }; return }
        for p in paths where !all.contains(p) {
            if job.localPath.isEmpty { job.localPath = p } else { extra.wrappedValue.append(p) }
        }
    }

    private func remove(at index: Int) {
        guard let extra = extraFolders else { return }
        if index == 0 {
            job.localPath = extra.wrappedValue.isEmpty ? "" : extra.wrappedValue.removeFirst()
        } else if index - 1 < extra.wrappedValue.count {
            extra.wrappedValue.remove(at: index - 1)
        }
    }

    private func choose(adding: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = extraFolders != nil
        panel.prompt = L("Choose")
        panel.message = extraFolders != nil ? L("Choose one or more folders to keep in sync. Hold ⌘ to select several.")
                                            : L("Choose the folder PigmentDev rClone should keep in sync.")
        if !job.localPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: (job.localPath as NSString).deletingLastPathComponent) }
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        if adding || extraFolders != nil { add(paths) } else if let p = paths.first { job.localPath = p }
    }
}

// MARK: - Remote browser

struct RemoteBrowser: View {
    @Environment(AppModel.self) private var model
    var accountID: String?
    @Binding var path: String

    @State private var current = ""
    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""
    @State private var newFolder = ""
    @State private var showNewFolder = false
    @State private var showPasteLink = false
    @State private var pastedLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                breadcrumb("Root", "")
                ForEach(Array(crumbs.enumerated()), id: \.offset) { _, c in
                    Image(systemName: "chevron.forward").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
                    breadcrumb(c.name, c.path)
                }
                Spacer()
                SearchField(text: $filter, prompt: "Filter").frame(width: 150)
                IconButton(symbol: "folder.badge.plus", help: L("New folder")) { newFolder = ""; showNewFolder = true }
                    .disabled(current == "@computers")
                IconButton(symbol: "arrow.clockwise", help: L("Reload")) { Task { await load() } }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.track.opacity(0.5))
                if loading {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if current == "@computers" {
                            Text("Looking for your computers… on a large Drive the first search can take a few minutes. After that it opens instantly.")
                                .font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                } else if let error {
                    Text(error).font(PDFont.text(12)).foregroundStyle(Brand.red).padding()
                } else if visible.isEmpty {
                    Text(filter.isEmpty ? "This folder is empty" : "No matching folders").font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visible) { e in
                                Button { open(e) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: e.path == "@computers" ? "laptopcomputer.and.iphone" : e.path.hasPrefix("@computer:") && !e.path.contains("/") ? "laptopcomputer" : e.isDir ? "folder.fill" : "doc")
                                            .foregroundStyle(e.isDir ? Brand.cobalt : Theme.textMuted)
                                        Text(e.name).font(PDFont.text(13)).foregroundStyle(Theme.text).lineLimit(1)
                                        Spacer()
                                        if e.isDir { Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted) }
                                        else { Text(Fmt.bytes(e.size)).font(PDFont.numbers(11)).foregroundStyle(Theme.textMuted) }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!e.isDir)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(minHeight: 160)
            if current == "@computers" {
                HStack(spacing: 8) {
                    Text("Computer not listed?").font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                    Button("Paste its folder link from drive.google.com…") { pastedLink = ""; showPasteLink = true }
                        .buttonStyle(.link).font(PDFont.text(12, .semibold))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                Text("Syncs into: ").font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
                + Text("/" + Fmt.remote(path)).font(PDFont.text(12.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if path.isEmpty || path == "/" {
                    Label("Top level of the storage. Open a folder to sync into it.", systemImage: "exclamationmark.triangle.fill")
                        .font(PDFont.text(11.5, .semibold)).foregroundStyle(Brand.orange)
                }
            }
        }
        .task(id: accountID) { current = path; await load() }
        .alert("Open a computer by link", isPresented: $showPasteLink) {
            TextField("https://drive.google.com/drive/folders/…", text: $pastedLink)
            Button("Open") {
                if let id = Self.folderID(from: pastedLink) { current = "@computer:\(id):" + L("Computer"); Task { await load() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("In Google Drive, open Computers, open your computer, and copy the address from the browser.") }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolder)
            Button("Create") { Task { await mkdir() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Created inside /\(Fmt.remote(current))") }
    }

    /// Folder ID from a drive.google.com folder link, or a bare ID.
    static func folderID(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "/folders/") {
            let id = t[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return id.isEmpty ? nil : String(id)
        }
        let ok = !t.isEmpty && t.count >= 10 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return ok ? t : nil
    }

    private var crumbs: [(name: String, path: String)] {
        if current == "@computers" { return [(L("Computers"), "@computers")] }
        if let c = Fmt.computer(current) {
            let base = "@computer:\(c.id):\(c.name)"
            var acc = base
            return [(L("Computers"), "@computers"), (c.name, base)] + c.sub.split(separator: "/").map { part in
                acc += "/" + part
                return (String(part), acc)
            }
        }
        var acc: [String] = []
        return current.split(separator: "/").map { part in
            acc.append(String(part))
            return (String(part), acc.joined(separator: "/"))
        }
    }

    private var visible: [RemoteEntry] {
        let dirsFirst = entries.sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
        guard !filter.isEmpty else { return dirsFirst }
        return dirsFirst.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func breadcrumb(_ name: String, _ p: String) -> some View {
        Button { current = p; if p != "@computers" { path = p }; Task { await load() } } label: {
            Text(LocalizedStringKey(name)).font(PDFont.text(12.5, current == p ? .bold : .medium))
                .foregroundStyle(current == p ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(current == p ? Theme.track : .clear))
        }
        .buttonStyle(.plain)
    }

    private func open(_ e: RemoteEntry) {
        guard e.isDir else { return }
        current = e.path.isEmpty ? (current.isEmpty ? e.name : current + "/" + e.name) : e.path
        if current != "@computers" { path = current } // the folder you're in is the one that syncs
        Task { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            // Finding Google Drive "Computers" pages through all your folders; give it time on big drives.
            let r = try await client.call("remote.list", RemoteListParams(accountId: accountID?.isEmpty == true ? nil : accountID, path: current, dirsOnly: true),
                                          as: RemoteListResult.self, timeout: current == "@computers" ? 600 : 60)
            entries = r.entries
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    private func mkdir() async {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.client else { return }
        let p = current.isEmpty ? name : current + "/" + name
        do {
            try await client.send("remote.mkdir", MkdirParams(accountId: accountID, path: p))
            current = p
            path = p
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Direction & policies

struct DirectionEditor: View {
    @Binding var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Which way should files flow?")
                HStack(spacing: 12) {
                    ForEach(SyncDirection.allCases, id: \.self) { d in
                        ChoiceCard(symbol: d.symbol, title: d.title, text: d.explanation, selected: job.direction == d) {
                            job.direction = d
                            if d == .twoWay && job.deletePolicy == .never { job.deletePolicy = .archive }
                        }
                    }
                }
                .pdGlassContainer(spacing: 12)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("When a file is deleted")
                Picker("Deletions", selection: $job.deletePolicy) {
                    ForEach(DeletePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(job.deletePolicy.explanation(for: job.direction, retentionDays: job.archiveRetentionDays))
                    .font(PDFont.text(12.5)).foregroundStyle(job.deletePolicy == .mirror ? Brand.red : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if job.deletePolicy == .archive {
                    Stepper(value: $job.archiveRetentionDays, in: 1...3650) {
                        Text("Keep archived files for \(job.archiveRetentionDays) days").font(PDFont.text(13))
                    }
                }
            }
            if job.direction == .twoWay {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("When both sides changed the same file")
                    Picker("Conflicts", selection: $job.conflictPolicy) {
                        ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(conflictExplanation).font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Safety")
                Stepper(value: $job.safety.maxDeletePercent, in: 0...100, step: 5) {
                    Text("Stop and ask if a run would delete more than \(job.safety.maxDeletePercent)% of files").font(PDFont.text(13))
                }
                Toggle("Show a dry-run preview before the first real run", isOn: $job.safety.dryRunFirst)
                Toggle("Compare checksums (slower, catches silent corruption)", isOn: $job.safety.checksum)
            }
            .toggleStyle(PDSwitchStyle())
        }
    }

    private var conflictExplanation: String {
        switch job.conflictPolicy {
        case .newer: return L("The most recently modified version wins; the other is archived.")
        case .keepBoth: return L("Both versions are kept; one is renamed with “conflict” and this Mac's name.")
        case .preferLocal: return L("The version on this Mac always wins.")
        case .preferRemote: return L("The version in the cloud always wins.")
        case .ask: return L("Nothing is overwritten; the conflict waits for you in the Action Center.")
        }
    }
}

struct ChoiceCard: View {
    var symbol: String
    var title: String
    var text: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? Brand.orange : Theme.textSecondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Brand.orange : Theme.hairline)
                }
                Text(title).font(PDFont.display(15, .heavy)).foregroundStyle(Theme.text)
                Text(text).font(PDFont.text(12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .pdGlass(radius: 20, tint: selected ? Brand.orange : nil, interactive: true)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? Brand.orange.opacity(0.7) : .clear, lineWidth: 1.5))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Schedule

struct ScheduleEditor: View {
    @Binding var triggers: Triggers

    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Start this job…")
            ToggleRow(symbol: "bolt.fill", title: "When files change", subtitle: "Watches the folder and syncs shortly after you save.", isOn: $triggers.onChange) {
                HStack {
                    Text("Wait").font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
                    Slider(value: Binding(get: { Double(triggers.debounceSec) }, set: { triggers.debounceSec = Int($0) }), in: 2...60, step: 1)
                        .tint(Brand.orange).frame(maxWidth: 220)
                    Text("\(triggers.debounceSec) s after the last change").font(PDFont.numbers(12.5)).foregroundStyle(Theme.text)
                }
            }
            ToggleRow(symbol: "timer", title: "On an interval", subtitle: "Every few minutes or every hour.", isOn: Binding(
                get: { triggers.intervalMin != nil }, set: { triggers.intervalMin = $0 ? (triggers.intervalMin ?? 30) : nil })) {
                HStack(spacing: 8) {
                    ForEach([5, 15, 30, 60, 180], id: \.self) { m in
                        ChipButton(title: m == 60 ? L("Hourly") : m > 60 ? "\(m / 60) h" : "\(m) min", selected: triggers.intervalMin == m) { triggers.intervalMin = m }
                    }
                    Stepper(value: Binding(get: { triggers.intervalMin ?? 30 }, set: { triggers.intervalMin = $0 }), in: 1...1440) {
                        Text("\(triggers.intervalMin ?? 30) min").font(PDFont.numbers(12.5))
                    }
                }
            }
            ToggleRow(symbol: "sun.max", title: "Every day", subtitle: "At a fixed time.", isOn: Binding(
                get: { triggers.daily != nil }, set: { triggers.daily = $0 ? (triggers.daily ?? "09:00") : nil })) {
                ClockPicker(value: Binding(get: { triggers.daily ?? "09:00" }, set: { triggers.daily = $0 }))
            }
            ToggleRow(symbol: "calendar", title: "Every week", subtitle: "On one weekday.", isOn: Binding(
                get: { triggers.weekly != nil }, set: { triggers.weekly = $0 ? (triggers.weekly ?? WeeklyTrigger(day: 1, time: "09:00")) : nil })) {
                HStack {
                    Picker("Day", selection: Binding(get: { triggers.weekly?.day ?? 1 }, set: { triggers.weekly?.day = $0 })) {
                        ForEach(1...7, id: \.self) { Text(LocalizedStringKey(Self.weekdays[$0 - 1])).tag($0) }
                    }
                    .pdSelect(width: 140)
                    ClockPicker(value: Binding(get: { triggers.weekly?.time ?? "09:00" }, set: { triggers.weekly?.time = $0 }))
                }
            }
            ToggleRow(symbol: "terminal", title: "Cron expression", subtitle: "Advanced: five fields, e.g. 0 */2 * * *.", isOn: Binding(
                get: { triggers.cron != nil }, set: { triggers.cron = $0 ? (triggers.cron ?? "0 */2 * * *") : nil })) {
                HStack {
                    TextField("0 */2 * * *", text: Binding(get: { triggers.cron ?? "" }, set: { triggers.cron = $0 }))
                        .textFieldStyle(PDFieldStyle()).font(PDFont.mono(12.5, .medium)).frame(maxWidth: 220)
                    if let c = triggers.cron {
                        Image(systemName: JobValidator.isValidCron(c) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(JobValidator.isValidCron(c) ? Brand.green : Brand.red)
                    }
                }
            }
            ToggleRow(symbol: "powersleep", title: "When the Mac wakes up", subtitle: "Catches up on anything missed while asleep.", isOn: $triggers.onWake) { EmptyView() }
            ToggleRow(symbol: "hand.tap", title: "Manually", subtitle: "Always available from the menu bar and Shortcuts.", isOn: $triggers.manual) { EmptyView() }
        }
    }

    static func summary(_ t: Triggers) -> String {
        var parts: [String] = []
        if t.onChange { parts.append(L("On change") + " (\(t.debounceSec)s)") }
        if let i = t.intervalMin { parts.append(i == 60 ? L("Hourly") : i % 60 == 0 ? L("Every %d h", i / 60) : L("Every %d min", i)) }
        if let d = t.daily { parts.append(L("Daily at") + " " + d) }
        if let w = t.weekly { parts.append(L(weekdays[max(0, min(6, w.day - 1))]) + " " + w.time) }
        if let c = t.cron { parts.append("cron " + c) }
        if t.onWake { parts.append(L("On wake")) }
        if parts.isEmpty { parts.append(L("Manual only")) }
        return parts.joined(separator: " · ")
    }
}

struct ToggleRow<Extra: View>: View {
    var symbol: String
    var title: String
    var subtitle: String
    @Binding var isOn: Bool
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Brand.orange : Theme.textMuted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill((isOn ? Brand.orange : Theme.textMuted).opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(title)).font(PDFont.text(13.5, .semibold)).foregroundStyle(Theme.text)
                    Text(LocalizedStringKey(subtitle)).font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Toggle(LocalizedStringKey(title), isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Brand.orange)
            }
            if isOn && !(Extra.self == EmptyView.self) {
                extra.padding(.leading, 42)
            }
        }
        .padding(14)
        .pdGlass(radius: 18)
    }
}

struct ChipButton: View {
    var title: String
    var selected: Bool
    var symbol: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)) }
                Text(title).font(PDFont.text(12, .semibold))
            }
            .foregroundStyle(selected ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(selected ? Brand.orange : Theme.track))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "HH:mm" string ⇄ DatePicker.
struct ClockPicker: View {
    @Binding var value: String
    var body: some View {
        DatePicker("Time", selection: Binding(get: {
            let p = value.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            value = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .frame(width: 100)
    }
}

// MARK: - Exclusions

struct ExclusionsEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var job: Job
    var jobID: String?

    @State private var testPath = ""
    @State private var testResult: ExplainResult?
    @State private var testedByDaemon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Skip these")
                FlowLayout(spacing: 8) {
                    ForEach(FilterPreset.all) { preset in
                        let on = job.filters.presets.contains(preset.id)
                        ChipButton(title: L(preset.title), selected: on, symbol: on ? "checkmark" : "plus") {
                            if on { job.filters.presets.removeAll { $0 == preset.id } } else { job.filters.presets.append(preset.id) }
                        }
                        .help(preset.rules.joined(separator: "  "))
                    }
                }
                Text("Hover a chip to see exactly what it skips. Recommended: version control, IDE & agents, dependencies and OS junk.")
                    .font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Custom rules")
                    Spacer()
                    Button("Import .gitignore…") { importGitignore() }.buttonStyle(.link).font(PDFont.text(12, .semibold))
                    Button { job.filters.rules.append(FilterRule(kind: .exclude, pattern: "")) } label: { Label("Add rule", systemImage: "plus") }
                        .pdSecondary(large: false)
                }
                if job.filters.rules.isEmpty {
                    Text("Rules use glob patterns like *.log, tmp/** or /Exports/**. An include rule wins over the presets.")
                        .font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                }
                ForEach(job.filters.rules.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Picker("Kind", selection: $job.filters.rules[i].kind) {
                            Text("Exclude").tag(FilterRule.Kind.exclude)
                            Text("Include").tag(FilterRule.Kind.include)
                        }
                        .pdSelect(width: 110)
                        TextField("Pattern, e.g. *.log", text: $job.filters.rules[i].pattern)
                            .textFieldStyle(PDFieldStyle()).font(PDFont.mono(12.5, .medium))
                        IconButton(symbol: "arrow.up", help: L("Move up")) { if i > 0 { job.filters.rules.swapAt(i, i - 1) } }.disabled(i == 0)
                        IconButton(symbol: "trash", help: L("Remove rule"), tint: Brand.red) { job.filters.rules.remove(at: i) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("More")
                HStack {
                    Toggle("Skip files larger than", isOn: Binding(get: { job.filters.maxSizeMB != nil }, set: { job.filters.maxSizeMB = $0 ? (job.filters.maxSizeMB ?? 2048) : nil }))
                    if job.filters.maxSizeMB != nil {
                        TextField("MB", value: Binding(get: { job.filters.maxSizeMB ?? 0 }, set: { job.filters.maxSizeMB = $0 }), format: .number)
                            .textFieldStyle(PDFieldStyle()).frame(width: 80)
                        Text("MB").font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Stepper(value: Binding(get: { Int(job.filters.minAgeSec) }, set: { job.filters.minAgeSec = Int64($0) }), in: 0...3600, step: 5) {
                    Text(job.filters.minAgeSec == 0 ? L("Sync files immediately") : L("Skip files modified in the last %d s (still being written)", Int(job.filters.minAgeSec)))
                        .font(PDFont.text(13))
                }
                Toggle("Respect .gitignore files found in the folder", isOn: $job.filters.respectGitignore)
                Toggle("Skip symbolic links", isOn: $job.filters.skipSymlinks)
                Toggle("Skip folders that contain a .nosync file", isOn: Binding(
                    get: { job.filters.excludeIfPresent.contains(".nosync") },
                    set: { on in if on { job.filters.excludeIfPresent.append(".nosync") } else { job.filters.excludeIfPresent.removeAll { $0 == ".nosync" } } }))
            }
            .toggleStyle(PDSwitchStyle())

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Test a path")
                HStack {
                    TextField("e.g. app/node_modules/react/index.js", text: $testPath)
                        .textFieldStyle(PDFieldStyle()).font(PDFont.mono(12.5, .medium))
                        .onSubmit { Task { await test() } }
                    Button("Test") { Task { await test() } }.pdSecondary(large: false).disabled(testPath.isEmpty)
                }
                if let r = testResult {
                    HStack(spacing: 8) {
                        Image(systemName: r.included ? "checkmark.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(r.included ? Brand.green : Brand.orange)
                        Text(r.included ? L("Will sync") : L("Skipped"))
                            .font(PDFont.text(13, .semibold)).foregroundStyle(Theme.text)
                        if let rule = r.rule { Text(L("by rule") + " ").font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary) + Text(rule).font(PDFont.mono(12, .medium)).foregroundStyle(Theme.text) }
                        if !testedByDaemon { Text("(estimate)").font(PDFont.text(11)).foregroundStyle(Theme.textMuted) }
                    }
                }
            }
        }
    }

    private func test() async {
        let local = FilterEvaluator.explain(relative(testPath), filters: job.filters)
        testResult = local
        testedByDaemon = false
        guard let id = jobID, !id.isEmpty, let client = model.client,
              let live = model.job(id), live.filters == job.filters else { return }
        if let r = try? await client.call("jobs.explain", ExplainParams(id: id, path: testPath), as: ExplainResult.self) {
            testResult = r
            testedByDaemon = true
        }
    }

    private func relative(_ p: String) -> String {
        if !job.localPath.isEmpty, p.hasPrefix(job.localPath) { return String(p.dropFirst(job.localPath.count)) }
        return p
    }

    private func importGitignore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        if !job.localPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: job.localPath) }
        panel.message = L("Choose a .gitignore or .rsync-filter file")
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let new = FilterEvaluator.rules(fromGitignore: text).filter { !job.filters.rules.contains($0) }
        job.filters.rules.append(contentsOf: new)
    }
}

// MARK: - Network

struct NetworkEditor: View {
    @Binding var job: Job
    @State private var newAllow = ""
    @State private var newDeny = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Connection")
                Toggle("Only sync on Wi-Fi or Ethernet", isOn: $job.network.wifiOnly)
                Toggle("Allow syncing over a phone hotspot or cellular", isOn: $job.network.allowCellular)
                Toggle("Allow syncing on networks marked as expensive or Low Data Mode", isOn: $job.network.allowExpensive)
            }
            HStack(alignment: .top, spacing: 16) {
                TokenList(title: "Only on these Wi-Fi networks", tokens: $job.network.ssidAllow, placeholder: "Network name", draft: $newAllow)
                TokenList(title: "Never on these Wi-Fi networks", tokens: $job.network.ssidDeny, placeholder: "Network name", draft: $newDeny)
            }
            Text("Wi-Fi names need Location permission — macOS treats network names as location data. They never leave this Mac.")
                .font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Power")
                Toggle("Pause while on battery", isOn: $job.network.pauseOnBattery)
                HStack {
                    Toggle("Pause when battery is below", isOn: Binding(get: { job.network.minBatteryPercent != nil }, set: { job.network.minBatteryPercent = $0 ? (job.network.minBatteryPercent ?? 20) : nil }))
                    if job.network.minBatteryPercent != nil {
                        Stepper(value: Binding(get: { job.network.minBatteryPercent ?? 20 }, set: { job.network.minBatteryPercent = $0 }), in: 5...95, step: 5) {
                            Text("\(job.network.minBatteryPercent ?? 20)%").font(PDFont.numbers(12.5))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Bandwidth & parallelism")
                LimitRow(title: "Limit upload to", value: $job.limits.bwUpKBps)
                LimitRow(title: "Limit download to", value: $job.limits.bwDownKBps)
                Stepper(value: $job.limits.transfers, in: 1...32) { Text("\(job.limits.transfers) files at a time").font(PDFont.text(13)) }
                Stepper(value: $job.limits.checkers, in: 1...64) { Text("\(job.limits.checkers) parallel checks").font(PDFont.text(13)) }
            }
        }
        .toggleStyle(PDSwitchStyle())
    }
}

struct LimitRow: View {
    var title: String
    @Binding var value: Int?
    var body: some View {
        HStack {
            Toggle(LocalizedStringKey(title), isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? 1024) : nil }))
            if value != nil {
                TextField("KB/s", value: Binding(get: { value ?? 0 }, set: { value = $0 }), format: .number)
                    .textFieldStyle(PDFieldStyle()).frame(width: 90)
                Text("KB/s").font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct TokenList: View {
    var title: String
    @Binding var tokens: [String]
    var placeholder: String
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            FlowLayout(spacing: 6) {
                ForEach(tokens, id: \.self) { t in
                    HStack(spacing: 4) {
                        Image(systemName: "wifi").font(.system(size: 9.5, weight: .bold))
                        Text(t).font(PDFont.text(12, .semibold))
                        Button { tokens.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.track))
                }
            }
            HStack(spacing: 6) {
                TextField(LocalizedStringKey(placeholder), text: $draft).textFieldStyle(PDFieldStyle()).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if let ssid = SystemMonitor.currentSSID(), !tokens.contains(ssid) {
                    Button("Add “\(ssid)”") { tokens.append(ssid) }.buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pdGlass(radius: 18)
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !tokens.contains(t) else { return }
        tokens.append(t)
        draft = ""
    }
}

// MARK: - Flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
