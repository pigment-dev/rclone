import AppKit
import RCloneKit
import SwiftUI

// MARK: - Wizard step

struct AccountStep: View {
    @Environment(AppModel.self) private var model
    @Binding var job: Job
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.accounts.isEmpty || adding {
                AddAccountFlow(onDone: { acc in
                    job.accountId = acc.id
                    job.remotePath = ""
                    adding = false
                }, onCancel: model.accounts.isEmpty ? nil : { adding = false })
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(model.accounts) { acc in
                        Button { job.accountId = acc.id; job.remotePath = "" } label: {
                            HStack(spacing: 12) {
                                ProviderIcon(id: acc.provider, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acc.name).font(PDFont.text(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(model.provider(acc.provider)?.name ?? acc.provider).font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Image(systemName: job.accountId == acc.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(job.accountId == acc.id ? Brand.orange : Theme.hairline)
                            }
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pdGlass(radius: 18, tint: job.accountId == acc.id ? Brand.orange : nil, interactive: true)
                    }
                    Button { adding = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(Brand.orange)
                                .frame(width: 38, height: 38).background(Circle().fill(Brand.orange.opacity(0.12)))
                            Text("Add account").font(PDFont.text(14, .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pdGlass(radius: 18, interactive: true)
                }
                .pdGlassContainer(spacing: 12)
            }
        }
    }
}

// MARK: - Add account flow

/// Provider grid → fields (generated from Field metadata) → OAuth in the browser → done.
struct AddAccountFlow: View {
    @Environment(AppModel.self) private var model
    var onDone: (Account) -> Void
    var onCancel: (() -> Void)?
    /// When set, re-authenticates this account via `accounts.reconnect` instead of adding a new one.
    var reconnect: Account? = nil

    enum Phase: Equatable { case pick, form, oauth(url: String), question(AddAccountQuestion), working, failed }

    @State private var provider: Provider?
    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var showAdvanced = false
    @State private var showAllOptions = false
    @State private var phase: Phase = .pick
    @State private var sessionID: String?
    @State private var answer = ""
    @State private var error: String?
    @State private var poll: Task<Void, Never>?
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if reconnect == nil {
                FlowSteps(titles: [L("Choose a service"), provider?.auth == .fields ? L("Connect") : L("Sign in"), L("Done")],
                          current: phase == .pick ? 0 : 1)
                    .padding(.bottom, 2)
            }
            switch phase {
            case .pick: picker
            case .form: form
            case .oauth(let url): oauth(url)
            case .question(let q): question(q)
            case .working:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Connecting…").font(PDFont.text(13)).foregroundStyle(Theme.textSecondary) }
                    .padding(18).pdGlass(radius: 20)
            case .failed:
                HStack {
                    Button("Try again") { if let r = reconnect { Task { await startReconnect(r) } } else { phase = .form } }.pdSecondary(large: false)
                    if let onCancel { Button("Cancel", action: onCancel).buttonStyle(.link) }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(PDFont.text(12.5)).foregroundStyle(Brand.red)
            }
        }
        .task {
            if model.providers.isEmpty { await model.refreshProviders() }
            if let r = reconnect, phase == .pick { await startReconnect(r) }
            // Screenshot hook: PDRCLONE_ADD_PROVIDER=<id> opens that provider's form (PDRCLONE_ADD_ADVANCED=1 expands it).
            let env = ProcessInfo.processInfo.environment
            if reconnect == nil, phase == .pick, let id = env["PDRCLONE_ADD_PROVIDER"], let p = model.provider(id) {
                choose(p)
                showAdvanced = env["PDRCLONE_ADD_ADVANCED"] == "1"
            }
        }
        .onDisappear { poll?.cancel() }
    }

    private var providers: [Provider] {
        let p = model.providers
        return showAll ? p : p.filter(\.popular).ifEmptyArray(p)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(showAll ? "All providers" : "Popular")
                Spacer()
                if model.providers.contains(where: { !$0.popular }) {
                    Button(showAll ? "Show popular" : "Show all \(model.providers.count)") { withAnimation { showAll.toggle() } }
                        .buttonStyle(.link).font(PDFont.text(12, .semibold))
                }
                if let onCancel { Button("Cancel", action: onCancel).buttonStyle(.link).font(PDFont.text(12, .semibold)) }
            }
            if model.providers.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading providers…").font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(providers) { p in
                    Button { choose(p) } label: {
                        VStack(spacing: 10) {
                            ProviderIcon(id: p.id, size: 44)
                            Text(p.name).font(PDFont.text(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(categoryTitle(p.category)).font(PDFont.mono(9.5)).textCase(.uppercase).tracking(1).foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pdGlass(radius: 20, interactive: true)
                }
            }
            .pdGlassContainer(spacing: 12)
        }
    }

    private func categoryTitle(_ c: Provider.Category) -> String {
        switch c {
        case .cloud: return L("Cloud drive")
        case .object: return L("Object storage")
        case .server: return L("Server")
        case .local: return L("Disk / NAS")
        }
    }

    private func choose(_ p: Provider) {
        provider = p
        name = p.name
        values = Dictionary(uniqueKeysWithValues: p.fields.map { ($0.name, $0.default?.stringValue ?? "") })
        error = nil
        phase = .form
    }

    private var visibleFields: [Field] {
        guard let p = provider else { return [] }
        let selected = values["provider"] ?? ""
        return p.fields.filter { RcloneHelp.applies($0, to: selected) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = provider {
                HStack(spacing: 12) {
                    ProviderIcon(id: p.id, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(PDFont.display(18, .heavy)).foregroundStyle(Theme.text)
                        Text(p.auth == .oauth ? L("Sign in with your browser. No passwords are typed here.") : L("Enter the connection details.")).font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Button("Back") { phase = .pick }.buttonStyle(.link)
                }
                let hasAdvanced = visibleFields.contains(where: \.advanced)
                if hasAdvanced {
                    Picker("", selection: $showAdvanced) {
                        Text(p.auth == .oauth ? "Sign in" : "Connection").tag(false)
                        Text(p.auth == .oauth ? "Advanced: own client ID and options" : "Advanced options").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if showAdvanced && hasAdvanced {
                    if p.auth == .oauth, p.fields.contains(where: { $0.name == "client_id" }) {
                        OwnClientIDGuide(providerID: p.id)
                    }
                    ForEach(keyAdvanced) { field in
                        FieldInput(field: field, providerID: p.id, value: binding(field))
                    }
                    if !otherAdvanced.isEmpty {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showAllOptions.toggle() } } label: {
                            Label(L("All rclone options (%d)", otherAdvanced.count), systemImage: showAllOptions ? "chevron.down" : "chevron.right")
                                .font(PDFont.text(12, .semibold)).foregroundStyle(Theme.textSecondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showAllOptions {
                            ForEach(otherAdvanced) { field in
                                FieldInput(field: field, providerID: p.id, value: binding(field))
                            }
                        }
                    }
                } else {
                    if p.auth == .oauth {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(oauthSteps(p).enumerated()), id: \.offset) { i, text in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(i + 1)").font(PDFont.numbers(11)).foregroundStyle(.white)
                                        .frame(width: 18, height: 18).background(Circle().fill(Brand.orange))
                                    Text(text).font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    LabeledField("Account name") { TextField("e.g. Work Drive", text: $name).textFieldStyle(.roundedBorder) }
                    ForEach(visibleFields.filter { !$0.advanced }) { field in
                        FieldInput(field: field, providerID: p.id, value: binding(field))
                    }
                }
                HStack {
                    if showAdvanced, !(values["client_id"] ?? "").isEmpty {
                        Label("Your own client ID will be used", systemImage: "checkmark.circle.fill")
                            .font(PDFont.text(11.5)).foregroundStyle(Brand.green)
                    }
                    Spacer()
                    signInButton(p)
                }
            }
        }
        .padding(20)
        .pdGlass(radius: 22)
    }

    /// Advanced options people actually change (own client ID, scope, root folder…); the rest are folded away.
    private static let keyOptionNames: Set<String> = ["client_id", "client_secret", "scope", "root_folder_id", "team_drive",
                                                       "service_account_file", "region", "shared_files", "shared_folders",
                                                       "skip_shortcuts", "drive_id", "drive_type", "tenant"]
    private var keyAdvanced: [Field] { visibleFields.filter { $0.advanced && Self.keyOptionNames.contains($0.name) } }
    private var otherAdvanced: [Field] { visibleFields.filter { $0.advanced && !Self.keyOptionNames.contains($0.name) } }

    private func signInButton(_ p: Provider) -> some View {
        Button { Task { await start(p) } } label: {
            Label(p.auth == .oauth ? L("Sign in with \(shortName(p))") : L("Connect"), systemImage: p.auth == .oauth ? "safari" : "link")
                .padding(.horizontal, 6)
        }
        .pdPrimary()
        .disabled(!formValid(p))
    }

    private func binding(_ field: Field) -> Binding<String> {
        Binding(get: { values[field.name] ?? "" }, set: { values[field.name] = $0 })
    }

    private func shortName(_ p: Provider) -> String {
        switch p.id {
        case "drive", "gcs": return "Google"
        case "onedrive": return "Microsoft"
        default: return p.name
        }
    }

    private func oauthSteps(_ p: Provider) -> [String] {
        [L("Click the button below. Your browser opens the \(shortName(p)) sign-in page."),
         L("Sign in and allow access. If the browser warns about an unverified app, choose Advanced and continue."),
         L("Come back here. The account is added by itself, and the sign-in token is stored encrypted on this Mac.")]
    }

    private func formValid(_ p: Provider) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            p.fields.filter(\.required).allSatisfy { !(values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func oauth(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Waiting for you to sign in…").font(PDFont.text(14, .semibold)).foregroundStyle(Theme.text)
                    Text("Finish signing in in your browser, then come back here. This page updates by itself.")
                        .font(PDFont.text(12)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack {
                Button("Open the sign-in page again") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }.pdSecondary(large: false)
                Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { Task { await cancel() } }.pdSecondary(large: false)
            }
        }
        .padding(18)
        .pdGlass(radius: 22, tint: Brand.cobalt)
    }

    private func question(_ q: AddAccountQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldInput(field: q.asField, providerID: provider?.id ?? "", value: $answer)
            HStack {
                Spacer()
                Button("Cancel") { Task { await cancel() } }.pdSecondary(large: false)
                Button("Continue") { Task { await continueFlow(answer: q.type == .bool ? .bool(answer == "true") : .string(answer)) } }.pdPrimary()
            }
        }
        .padding(18)
        .pdGlass(radius: 22)
    }

    // MARK: Flow

    private func start(_ p: Provider) async {
        guard let client = model.client else { return }
        error = nil
        phase = .working
        var fields: [String: JSONValue] = [:]
        for f in visibleFields {
            let v = values[f.name] ?? ""
            if v.isEmpty { continue }
            switch f.type {
            case .bool: fields[f.name] = .bool(v == "true")
            case .int: fields[f.name] = Double(v).map(JSONValue.number) ?? .string(v)
            default: fields[f.name] = .string(v)
            }
        }
        do {
            let r = try await client.call("accounts.add.start", AddAccountStartParams(provider: p.id, name: name, fields: fields), as: AddAccountResult.self, timeout: 60)
            await handle(r)
        } catch {
            self.error = error.localizedDescription
            phase = .form
        }
    }

    private func startReconnect(_ acc: Account) async {
        guard let client = model.client else { return }
        error = nil
        phase = .working
        provider = model.provider(acc.provider)
        name = acc.name
        do {
            let r = try await client.call("accounts.reconnect", IDParams(acc.id), as: AddAccountResult.self, timeout: 60)
            await handle(r)
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    private func continueFlow(answer: JSONValue) async {
        guard let client = model.client, let sid = sessionID else { return }
        do {
            let r = try await client.call("accounts.add.continue", AddAccountContinueParams(sessionId: sid, answer: answer), as: AddAccountResult.self, timeout: 60)
            await handle(r)
        } catch {
            self.error = error.localizedDescription
            phase = reconnect == nil ? .form : .failed
        }
    }

    private func handle(_ r: AddAccountResult) async {
        if let s = r.sessionId { sessionID = s }
        switch r.state {
        case .done:
            poll?.cancel()
            await model.refreshAccounts()
            if let acc = r.account ?? model.accounts.last { onDone(acc) }
        case .needsOAuth:
            let url = r.authUrl ?? ""
            if phase != .oauth(url: url) {
                phase = .oauth(url: url)
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
            startPolling()
        case .needsInput:
            poll?.cancel()
            answer = r.question?.default?.stringValue ?? ""
            if let q = r.question { phase = .question(q) }
        case .error:
            poll?.cancel()
            error = r.error ?? L("The provider rejected the connection.")
            phase = reconnect == nil ? .form : .failed
        }
    }

    private func startPolling() {
        guard poll == nil || poll?.isCancelled == true else { return }
        poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let client = model.client, let sid = sessionID else { return }
                do {
                    let r = try await client.call("accounts.add.continue", AddAccountContinueParams(sessionId: sid, answer: .null), as: AddAccountResult.self, timeout: 30)
                    if r.state != .needsOAuth {
                        poll = nil
                        await handle(r)
                        return
                    }
                } catch {
                    self.error = error.localizedDescription
                    phase = .form
                    poll = nil
                    return
                }
            }
        }
    }

    private func cancel() async {
        poll?.cancel(); poll = nil
        if let sid = sessionID, let client = model.client { try? await client.send("accounts.add.cancel", SessionParams(sid)) }
        sessionID = nil
        phase = reconnect == nil ? .form : .failed
    }
}

/// One input generated from provider Field metadata.
struct FieldInput: View {
    var field: Field
    var providerID: String = ""
    @Binding var value: String
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(field.label.isEmpty ? field.name : field.label).font(PDFont.text(12.5, .semibold)).foregroundStyle(Theme.text)
                if field.required { Text("*").foregroundStyle(Brand.orange) }
            }
            switch field.type {
            case .password:
                SecureField(RcloneHelp.placeholder(for: field), text: $value).textFieldStyle(.roundedBorder)
            case .bool:
                Toggle(isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" })) { EmptyView() }
                    .toggleStyle(.switch).tint(Brand.orange).labelsHidden()
            case .select:
                Picker(field.label, selection: $value) {
                    if !field.required { Text("Default").tag("") }
                    ForEach(field.options, id: \.self) { Text($0.label.isEmpty ? $0.value : $0.label).tag($0.value) }
                }
                .labelsHidden()
            case .int:
                TextField(RcloneHelp.placeholder(for: field), text: $value).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
            case .string:
                HStack(spacing: 6) {
                    TextField(RcloneHelp.placeholder(for: field), text: $value).textFieldStyle(.roundedBorder)
                    if !field.options.isEmpty {
                        Menu {
                            ForEach(field.options, id: \.self) { o in
                                Button(o.label.isEmpty || o.label == o.value ? o.value : "\(o.value) — \(o.label)") { value = o.value }
                            }
                        } label: { Text("Choose") }
                        .menuStyle(.button).fixedSize()
                    }
                }
            }
            if !field.help.isEmpty {
                let help = RcloneHelp.split(field.help, provider: providerID)
                Text(help.summary).font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let more = help.more {
                    if showMore {
                        Text(more).font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Button(showMore ? "Less" : "More") { withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() } }
                        .buttonStyle(.link).font(PDFont.text(11.5, .semibold))
                }
            }
        }
    }
}

extension Array {
    func ifEmptyArray(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

// MARK: - Accounts page

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var adding = false
    @State private var testing: Set<String> = []
    @State private var results: [String: AccountTestResult] = [:]
    @State private var renaming: Account?
    @State private var newName = ""
    @State private var removing: Account?

    var body: some View {
        Page {
            PageHeader(title: "Accounts", subtitle: "Cloud drives, buckets and servers this Mac can sync with.") {
                Button { adding = true } label: { Label("Add account", systemImage: "plus") }.pdPrimary().disabled(!model.isConnected)
            }
            if model.accounts.isEmpty {
                GlassCard { EmptyState(symbol: "person.crop.circle.badge.plus", title: "No accounts yet", message: "Connect Google Drive, OneDrive, Dropbox, S3, SFTP and more.") }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(model.accounts) { acc in card(acc) }
            }
            .pdGlassContainer(spacing: 16)
            GlassCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key.horizontal").foregroundStyle(Brand.cobalt)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Credentials stay on this Mac").font(PDFont.text(13, .semibold)).foregroundStyle(Theme.text)
                        Text("Tokens and passwords are stored in an encrypted rclone config whose key lives in your Keychain. They are never logged.")
                            .font(PDFont.text(12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .onAppear { if ProcessInfo.processInfo.environment["PDRCLONE_ADD_PROVIDER"] != nil { adding = true } }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add an account").font(PDFont.display(22, .black)).foregroundStyle(Theme.text)
                ScrollView { AddAccountFlow(onDone: { _ in adding = false }, onCancel: { adding = false }) }
            }
            .padding(28)
            .frame(width: 720, height: 600)
            .background(Backdrop())
            .environment(model)
        }
        .sheet(isPresented: Binding(get: { router.reconnectAccountID != nil }, set: { if !$0 { router.reconnectAccountID = nil } })) {
            if let acc = model.account(router.reconnectAccountID) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ProviderIcon(id: acc.provider, size: 40)
                        Text("Reconnect \(acc.name)").font(PDFont.display(22, .black)).foregroundStyle(Theme.text)
                    }
                    ScrollView {
                        AddAccountFlow(onDone: { _ in router.reconnectAccountID = nil; Task { await model.refreshActions() } },
                                       onCancel: { router.reconnectAccountID = nil }, reconnect: acc)
                    }
                }
                .padding(28)
                .frame(width: 620, height: 460)
                .background(Backdrop())
                .environment(model)
            }
        }
        .alert("Rename account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let acc = renaming {
                    Task { await model.perform { try await $0.send("accounts.rename", RenameParams(id: acc.id, name: newName)) }; await model.refreshAccounts() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove account", role: .destructive) { if let a = removing { Task { await remove(a, force: false) } } }
            let used = model.jobs.filter { $0.accountId == removing?.id }.count
            if used > 0 { Button("Remove it and its \(used) jobs", role: .destructive) { if let a = removing { Task { await remove(a, force: true) } } } }
        } message: {
            Text("Files in the cloud are not deleted. Jobs that use this account stop syncing.")
        }
    }

    private func card(_ acc: Account) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderIcon(id: acc.provider, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(acc.name).font(PDFont.display(16, .heavy)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(model.provider(acc.provider)?.name ?? acc.provider).font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Pill(text: acc.status.title, symbol: acc.status == .ok ? "checkmark" : "exclamationmark", color: acc.status == .ok ? Brand.green : acc.status == .needsAuth ? Brand.orange : Brand.red)
            }
            if let q = acc.quota, let used = q.used {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressTrack(fraction: q.usedFraction ?? 0, tint: (q.usedFraction ?? 0) > 0.9 ? Brand.red : ProviderIcon(id: acc.provider).color, height: 7)
                    HStack {
                        Text(Fmt.bytes(used) + " " + L("used")).font(PDFont.numbers(11.5)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let free = q.free { Text(Fmt.bytes(free) + " " + L("free")).font(PDFont.numbers(11.5)).foregroundStyle(Theme.textMuted) }
                        if let total = q.total { Text("/ " + Fmt.bytes(total)).font(PDFont.numbers(11.5)).foregroundStyle(Theme.textMuted) }
                    }
                }
            } else {
                Text("Storage usage isn't reported by this provider").font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
            }
            if let e = acc.error { Text(e).font(PDFont.text(11.5)).foregroundStyle(Brand.red).lineLimit(2) }
            if let r = results[acc.id] {
                Label(r.ok ? L("Connection works") + (r.latencyMs.map { " · \($0) ms" } ?? "") : (r.error ?? L("Test failed")),
                      systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(PDFont.text(12)).foregroundStyle(r.ok ? Brand.green : Brand.red)
            }
            HStack(spacing: 8) {
                Button { Task { await test(acc) } } label: {
                    if testing.contains(acc.id) { ProgressView().controlSize(.small) } else { Label("Test", systemImage: "stethoscope") }
                }
                .pdSecondary(large: false)
                if acc.status == .needsAuth || acc.status == .error {
                    Button { router.reconnectAccountID = acc.id } label: { Label("Reconnect", systemImage: "arrow.triangle.2.circlepath") }.pdPrimary()
                }
                Spacer()
                Text("\(model.jobs.filter { $0.accountId == acc.id }.count) jobs").font(PDFont.text(11.5)).foregroundStyle(Theme.textMuted)
                Menu {
                    Button("Rename…") { newName = acc.name; renaming = acc }
                    Button("Refresh storage") { Task { await model.perform { _ = try await $0.call("accounts.quota", IDParams(acc.id), as: QuotaResult.self) }; await model.refreshAccounts() } }
                    Divider()
                    Button("Remove…", role: .destructive) { removing = acc }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).pdSecondary(large: false).fixedSize()
            }
        }
        .padding(20)
        .pdGlass(radius: Theme.cardRadius)
    }

    private func test(_ acc: Account) async {
        guard let client = model.client else { return }
        testing.insert(acc.id)
        defer { testing.remove(acc.id) }
        do { results[acc.id] = try await client.call("accounts.test", IDParams(acc.id), as: AccountTestResult.self, timeout: 60) }
        catch { var r = AccountTestResult(); r.error = error.localizedDescription; results[acc.id] = r }
    }

    private func remove(_ acc: Account, force: Bool) async {
        if await model.perform({ try await $0.send("accounts.remove", RemoveAccountParams(id: acc.id, force: force)) }) {
            await model.refreshAccounts()
            await model.refreshJobs()
        }
    }
}
