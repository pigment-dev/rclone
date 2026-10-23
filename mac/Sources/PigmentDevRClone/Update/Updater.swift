import AppKit
import CryptoKit
import Foundation
import Observation
import RCloneKit
import Security

/// Self-updater (same approach as Hush/KeepMeUp; no Sparkle):
/// reads GitHub Releases for pigment-dev/rclone, downloads the .zip, verifies its EdDSA (Ed25519)
/// signature (`.zip.sig`) against `PDRClonePublicEDKey` in Info.plist, checks the code signature identifier,
/// then swaps the bundle and relaunches.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL?
        let signature: URL?
        let notes: String
        let prerelease: Bool
    }

    enum Phase: Equatable { case idle, checking, upToDate, available, downloading, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var latest: Release?
    @ObservationIgnored private var timer: Timer?

    static let repo = "pigment-dev/rclone"

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func startAutomaticChecks(channel: String) {
        check(channel: channel, quiet: true)
        timer?.invalidate()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AppEnvironment.shared.prefs.autoCheckUpdates else { return }
                self.check(channel: AppEnvironment.shared.prefs.updateChannel, quiet: true)
            }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check(channel: String = "stable", quiet: Bool = false) {
        if phase == .checking || phase == .downloading { return }
        if !quiet { phase = .checking }
        // Stable: /releases/latest (never a prerelease). Beta: newest of /releases including prereleases.
        let url = URL(string: channel == "beta" ? "https://api.github.com/repos/\(Self.repo)/releases?per_page=10"
                                                : "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PigmentDevRClone/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        Task {
            let result = try? await URLSession.shared.data(for: request)
            let release = result.flatMap { Self.parse($0.0, beta: channel == "beta") }
            guard let release else {
                if !quiet { phase = .failed(L("Couldn't reach GitHub")) } else { phase = .idle }
                return
            }
            latest = release
            phase = Self.isNewer(release.version, than: currentVersion) ? .available : .upToDate
        }
    }

    func install() {
        guard let latest, let download = latest.download, let signatureURL = latest.signature else {
            if let page = latest?.page { NSWorkspace.shared.open(page) }
            return
        }
        phase = .downloading
        Task {
            do {
                let (signatureData, _) = try await URLSession.shared.data(from: signatureURL)
                let (location, _) = try await URLSession.shared.download(from: download)
                let archive = try Data(contentsOf: location)
                guard Self.verify(archive, signature: signatureData) else {
                    try? FileManager.default.removeItem(at: location)
                    throw UpdateError.message(L("The update isn't signed with PigmentDev's release key."))
                }
                let app = try Self.unpack(location)
                replaceAndRelaunch(with: app)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func verify(_ data: Data, signature: Data) -> Bool {
        guard let keyText = Bundle.main.object(forInfoDictionaryKey: "PDRClonePublicEDKey") as? String, !keyText.isEmpty,
              let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(raw, for: data)
    }

    nonisolated private static func unpack(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pdrclone-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: zip, to: archive)
        guard runTool("/usr/bin/ditto", ["-x", "-k", archive.path, work.path]) == 0 else {
            throw UpdateError.message(L("Couldn't unzip the update."))
        }
        let app = work.appendingPathComponent("PigmentDev rClone.app")
        guard Bundle(url: app)?.bundleIdentifier == "com.pigmentdev.rclone" else {
            throw UpdateError.message(L("The download doesn't look like PigmentDev rClone."))
        }
        guard hasValidSignature(app) else { throw UpdateError.message(L("The update's code signature couldn't be verified.")) }
        return app
    }

    private func replaceAndRelaunch(with app: URL) {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            NSWorkspace.shared.activateFileViewerSelecting([app])
            phase = .failed(L("Couldn't write to %@. Drag the new app there yourself.", current.deletingLastPathComponent().path))
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(Self.quoted(current.path))
        mv \(Self.quoted(app.path)) \(Self.quoted(current.path))
        xattr -dr com.apple.quarantine \(Self.quoted(current.path)) 2>/dev/null
        open \(Self.quoted(current.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do { try p.run(); NSApp.terminate(nil) } catch { phase = .failed(error.localizedDescription) }
    }

    nonisolated private static func hasValidSignature(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"com.pigmentdev.rclone\"" as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    nonisolated static func parse(_ data: Data, beta: Bool) -> Release? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let candidates: [[String: Any]]
        if let list = json as? [[String: Any]] { candidates = list.filter { ($0["draft"] as? Bool) != true } }
        else if let one = json as? [String: Any] { candidates = [one] }
        else { return nil }
        guard let r = candidates.first(where: { beta || ($0["prerelease"] as? Bool) != true }),
              let tag = r["tag_name"] as? String,
              let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = r["assets"] as? [[String: Any]] ?? []
        func asset(_ suffix: String) -> URL? {
            (assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, download: asset(".zip"),
                       signature: asset(".zip.sig"), notes: r["body"] as? String ?? "", prerelease: r["prerelease"] as? Bool ?? false)
    }

    nonisolated static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    nonisolated static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let t) = self { return t }; return nil }
    }
}
