import AppKit
import RCloneKit
import SwiftUI

/// rclone status: the copy built into the sync service, the newest rclone release,
/// and an optional rclone command-line install (Homebrew) that can be updated from here.
@MainActor
@Observable
final class RcloneStatus {
    enum Check: Equatable { case idle, checking, done, failed(String) }

    private(set) var latest: String?
    private(set) var check: Check = .idle
    private(set) var cliPath: String?
    private(set) var cliVersion: String?
    private(set) var brewPath: String?
    private(set) var working = false
    private(set) var output = ""

    static let shared = RcloneStatus()
    private static let lastCheckKey = "rcloneLastCheck"
    private static let latestKey = "rcloneLatest"

    init() { latest = UserDefaults.standard.string(forKey: Self.latestKey) }

    /// Checks GitHub at most once a day unless forced.
    func refresh(force: Bool = false) async {
        await detectCLI()
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if !force, latest != nil, Date().timeIntervalSince1970 - last < 86_400 { check = .done; return }
        check = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/rclone/rclone/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Decodable { let tag_name: String }
            let tag = try JSONDecoder().decode(R.self, from: data).tag_name
            latest = tag
            UserDefaults.standard.set(tag, forKey: Self.latestKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            check = .done
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    func detectCLI() async {
        let candidates = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]
        cliPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let p = cliPath {
            let out = await Self.run(p, ["version"])
            cliVersion = out.split(separator: "\n").first.flatMap { $0.split(separator: " ").last.map(String.init) }
        } else {
            cliVersion = nil
        }
    }

    var cliIsBrew: Bool { cliPath.map { $0.hasPrefix("/opt/homebrew") || $0.hasPrefix("/usr/local") } ?? false }

    /// `brew upgrade rclone`, or `brew install rclone` when it isn't installed.
    func brew(_ install: Bool) async {
        guard let brew = brewPath else { return }
        working = true
        output = ""
        output = await Self.run(brew, [install ? "install" : "upgrade", "rclone"], env: ["HOMEBREW_NO_ENV_HINTS": "1"])
        working = false
        await detectCLI()
    }

    static func isNewer(_ a: String?, than b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return Updater.isNewer(a.trimmingCharacters(in: CharacterSet(charactersIn: "v")), than: b.trimmingCharacters(in: CharacterSet(charactersIn: "v")))
    }

    nonisolated static func run(_ path: String, _ args: [String], env: [String: String] = [:]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var e = ProcessInfo.processInfo.environment
                e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env.forEach { e[$0.key] = $0.value }
                p.environment = e
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: error.localizedDescription); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

struct RcloneEngineGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @State private var status = RcloneStatus.shared
    private let updater = AppEnvironment.shared.updater

    private var builtIn: String? { model.hello?.rcloneVersion }

    var body: some View {
        SettingsGroup(title: "rclone", footer: "rClone has its own copy of rclone inside the sync service, so you don't need to install rclone. The command-line rclone is only for use in Terminal.") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("Built in").font(PDFont.text(12.5, .semibold))
                    builtInStatus
                }
                GridRow {
                    Text("Command line").font(PDFont.text(12.5, .semibold))
                    cliStatus
                }
            }
            HStack {
                if status.check == .checking { ProgressView().controlSize(.small) }
                if case .failed(let m) = status.check {
                    Label(m, systemImage: "exclamationmark.triangle.fill").font(PDFont.text(11.5)).foregroundStyle(Brand.red).lineLimit(2)
                }
                Spacer()
                Button("Check for new rclone versions") { Task { await status.refresh(force: true) } }.pdSecondary(large: false)
            }
            if !status.output.isEmpty {
                ScrollView {
                    Text(status.output).font(PDFont.mono(10.5, .regular)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.track))
            }
        }
        .task { await status.refresh() }
    }

    @ViewBuilder private var builtInStatus: some View {
        HStack(spacing: 8) {
            Text(builtIn ?? "—").font(PDFont.mono(12, .medium))
            if RcloneStatus.isNewer(status.latest, than: builtIn) {
                Label(L("rclone %@ is out", status.latest ?? ""), systemImage: "arrow.down.circle.fill").foregroundStyle(Brand.orange)
                Button(updater.phase == .available ? L("Install rClone update") : L("Check for rClone update")) {
                    if updater.phase == .available { updater.install() } else { updater.check(channel: prefs.updateChannel) }
                }
                .buttonStyle(.link)
            } else if status.latest != nil {
                Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
            }
        }
        .font(PDFont.text(12.5))
        .help(L("The built-in rclone is updated together with rClone. New rclone versions ship in the next rClone release."))
    }

    @ViewBuilder private var cliStatus: some View {
        HStack(spacing: 8) {
            if let v = status.cliVersion {
                Text(v).font(PDFont.mono(12, .medium))
                if RcloneStatus.isNewer(status.latest, than: v) {
                    Label(L("%@ available", status.latest ?? ""), systemImage: "arrow.down.circle.fill").foregroundStyle(Brand.orange)
                    if status.cliIsBrew, status.brewPath != nil {
                        Button(status.working ? L("Updating…") : L("Update with Homebrew")) { Task { await status.brew(false) } }
                            .pdSecondary(large: false).disabled(status.working)
                    }
                } else if status.latest != nil {
                    Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
                }
            } else {
                Text("Not installed (not needed)").foregroundStyle(Theme.textMuted)
                if status.brewPath != nil {
                    Button(status.working ? L("Installing…") : L("Install with Homebrew")) { Task { await status.brew(true) } }
                        .buttonStyle(.link).disabled(status.working)
                }
            }
        }
        .font(PDFont.text(12.5))
    }
}
