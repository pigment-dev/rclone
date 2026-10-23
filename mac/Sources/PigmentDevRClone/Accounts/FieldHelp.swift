import RCloneKit
import SwiftUI

/// Turns rclone option help (Markdown with page-relative anchors and bare URLs) into clickable text.
enum RcloneHelp {
    /// rclone.org page for each provider id.
    static func docsURL(_ providerID: String) -> String {
        let page: String
        switch providerID {
        case "gcs": page = "googlecloudstorage"
        case "": return "https://rclone.org/docs/"
        default: page = providerID
        }
        return "https://rclone.org/\(page)/"
    }

    /// First paragraph, and the rest (if any), both with working links.
    static func split(_ help: String, provider: String) -> (summary: AttributedString, more: AttributedString?) {
        let paragraphs = help.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        let summary = render(paragraphs.first ?? "", provider: provider)
        let rest = paragraphs.dropFirst().joined(separator: "\n\n")
        return (summary, rest.isEmpty ? nil : render(rest, provider: provider))
    }

    static func render(_ text: String, provider: String) -> AttributedString {
        var s = text
        // [label](#anchor) → absolute rclone.org link
        s = s.replacingOccurrences(of: "](#", with: "](\(docsURL(provider))#")
        // bare URLs → Markdown links (skip ones already inside (...) or <...>)
        if let re = try? NSRegularExpression(pattern: #"(?<![(<\[])\bhttps?://[^\s)<>\]]+[^\s)<>\].,;:]"#) {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let url = ns.substring(with: m.range)
                out += "[\(url)](\(url))"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(text)
        for run in a.runs where run.link != nil {
            a[run.range].foregroundColor = Brand.cobalt
            a[run.range].underlineStyle = .single
        }
        return a
    }

    /// Placeholder shown inside an empty input.
    static func placeholder(for field: Field) -> String {
        if let d = field.default?.stringValue, !d.isEmpty, d != "false", d != "0" { return d }
        switch field.name {
        case "client_id": return L("Leave blank to use the built-in ID")
        case "client_secret": return L("Leave blank to use the built-in secret")
        case "root_folder_id": return L("Leave blank for the whole drive, or paste a folder ID")
        case "team_drive": return L("Leave blank for My Drive")
        case "service_account_file": return L("Path to a service account JSON file (optional)")
        case "host": return L("e.g. files.example.com")
        case "user": return L("e.g. deploy")
        case "port": return "22"
        case "endpoint": return L("e.g. https://s3.example.com")
        case "region": return L("e.g. us-east-1")
        case "key_file": return L("e.g. ~/.ssh/id_ed25519")
        case "url": return L("e.g. https://cloud.example.com/remote.php/dav/files/me")
        default: break
        }
        if !field.options.isEmpty { return L("Choose or type a value") }
        return field.required ? L("Required") : L("Optional")
    }

    /// rclone `provider` filter on an option, e.g. "AWS,Ceph" or "!AWS,Minio".
    static func applies(_ field: Field, to selected: String) -> Bool {
        guard let filter = field.provider, !filter.isEmpty else { return true }
        let negate = filter.hasPrefix("!")
        let list = (negate ? String(filter.dropFirst()) : filter).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if selected.isEmpty { return negate }
        return negate ? !list.contains(selected) : list.contains(selected)
    }
}

/// Small "1 · 2 · 3" progress header for the add-account flow.
struct FlowSteps: View {
    var titles: [String]
    var current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i < current ? Brand.green : i == current ? Brand.orange : Theme.track)
                        if i < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text(verbatim: Fmt.digits("\(i + 1)")).font(PDFont.numbers(10.5)).foregroundStyle(i == current ? .white : Theme.textMuted)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(LocalizedStringKey(title)).font(PDFont.text(12, i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? Theme.text : Theme.textMuted)
                }
                if i < titles.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(width: 22, height: 1)
                }
            }
        }
    }
}

/// Step-by-step guide for creating your own OAuth client ID.
struct OwnClientIDGuide: View {
    var providerID: String

    private struct Step: Identifiable {
        let id = UUID()
        let text: String
        var link: (title: String, url: String)? = nil
    }

    private var steps: [Step] {
        switch providerID {
        case "drive":
            return [
                Step(text: L("Create a Google Cloud project (any name, e.g. “rClone”) and make sure it is selected at the top of the page."), link: (L("Create project"), "https://console.cloud.google.com/projectcreate")),
                Step(text: L("Enable the Google Drive API for that project."), link: (L("Enable Drive API"), "https://console.cloud.google.com/apis/library/drive.googleapis.com")),
                Step(text: L("Create the consent screen: app name, your email as support and contact email, audience External."), link: (L("Create consent screen"), "https://console.cloud.google.com/auth/overview/create")),
                Step(text: L("On Audience, click Publish app (so sign-in doesn't expire after 7 days), or add your Gmail address as a test user."), link: (L("Open Audience"), "https://console.cloud.google.com/auth/audience")),
                Step(text: L("Create an OAuth client: Application type “Desktop app”, any name. Google shows the Client ID and Client secret."), link: (L("Create OAuth client"), "https://console.cloud.google.com/auth/clients/create")),
                Step(text: L("Paste the Client ID and Client secret into the fields below, then click Sign in with Google. If Google says the app isn't verified, click Advanced › Go to the app: it is your own app.")),
            ]
        case "onedrive":
            return [
                Step(text: L("Register a new app. Supported accounts: “Any Entra ID directory and personal Microsoft accounts”. Redirect URI: Web, http://localhost:53682/"), link: (L("Register an app"), "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade/quickStartType~/null/isMSAApp~/false")),
                Step(text: L("Under Certificates & secrets, create a client secret and copy its Value.")),
                Step(text: L("Under API permissions, add Microsoft Graph delegated permissions: Files.Read, Files.ReadWrite, Files.Read.All, Files.ReadWrite.All, offline_access, User.Read.")),
                Step(text: L("Copy the Application (client) ID and the secret value into the fields below.")),
            ]
        case "dropbox":
            return [
                Step(text: L("Create an app in the Dropbox App Console with “Full Dropbox” access."), link: (L("App Console"), "https://www.dropbox.com/developers/apps/create")),
                Step(text: L("On the Permissions tab, enable files.metadata.read/write and files.content.read/write, then Submit.")),
                Step(text: L("On the Settings tab, add the redirect URI http://localhost:53682/")),
                Step(text: L("Copy the App key and App secret into the Client ID and Client secret fields below.")),
            ]
        default:
            return [Step(text: L("Follow the provider's guide, then paste the client ID and secret below."), link: (L("rclone guide"), RcloneHelp.docsURL(providerID)))]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.viewfinder").foregroundStyle(Brand.cobalt)
                Text("Use your own client ID").font(PDFont.text(13, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Link("Full guide", destination: URL(string: "https://pigment.dev/kb/rclone-use-your-own-oauth-client-id/")!).font(PDFont.text(12, .semibold))
            }
            Text("Optional. The built-in ID is shared by every rclone user and can hit rate limits or be retired by the provider. Your own ID is free and takes about five minutes.")
                .font(PDFont.text(11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: Fmt.digits("\(i + 1)")).font(PDFont.numbers(11)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(Brand.cobalt))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.text).font(PDFont.text(12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let link = step.link, let u = URL(string: link.url) {
                            Link(destination: u) { Label(link.title, systemImage: "arrow.up.right.square") }.font(PDFont.text(11.5, .semibold))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.cobalt.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.cobalt.opacity(0.18)))
    }
}
