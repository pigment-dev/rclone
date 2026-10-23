import AppKit
import RCloneKit
import SwiftUI

struct ActionCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Page {
            PageHeader(title: "Action Center", subtitle: "Everything that's running, waiting, or needs a decision from you.") {
                HStack(spacing: 8) {
                    Button { Task { await model.refreshActions() } } label: { Image(systemName: "arrow.clockwise") }.pdSecondary()
                    Button("Dismiss all") { Task { await model.dismissAll() } }.pdSecondary().disabled(model.unresolvedActions.isEmpty)
                }
            }
            section("Running", symbol: "bolt.fill", tint: Brand.orange, count: model.runningJobs.count) {
                ForEach(model.runningJobs) { job in
                    JobRow(job: job).padding(16).pdGlass(radius: 20, tint: Brand.orange)
                        .onTapGesture { router.show(.jobs, job: job.id) }
                }
            }
            section("Needs attention", symbol: "exclamationmark.bubble.fill", tint: Brand.red, count: attention.count) {
                ForEach(attention) { ActionCard(action: $0) }
            }
            section("Waiting", symbol: "hourglass", tint: Brand.cobalt, count: waiting.count) {
                ForEach(waiting) { job in
                    HStack(spacing: 12) {
                        Image(systemName: job.state == .paused ? "pause.circle.fill" : "hourglass")
                            .foregroundStyle(Brand.cobalt).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name).font(PDFont.text(13.5, .semibold)).foregroundStyle(Theme.text)
                            Text(job.status?.reason ?? (job.state == .paused ? L("Paused by you") : L("Waiting for the right conditions")))
                                .font(PDFont.text(12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if job.state == .paused {
                            Button("Resume") { Task { await model.resume(job.id) } }.pdSecondary(large: false)
                        } else {
                            Button("Run anyway") { Task { await model.run(job.id) } }.pdSecondary(large: false)
                        }
                    }
                    .padding(16).pdGlass(radius: 20)
                }
            }
            section("Recent", symbol: "clock.arrow.circlepath", tint: Theme.textMuted, count: recent.count) {
                ForEach(recent) { ActionCard(action: $0, compact: true) }
            }
        }
    }

    private var attention: [Action] { model.unresolvedActions.filter(\.needsAttention).sorted { $0.createdAt > $1.createdAt } }
    private var waiting: [Job] { model.jobs.filter { $0.state == .waiting || $0.state == .paused || $0.state == .queued } }
    private var recent: [Action] {
        Array(model.actions.filter { $0.resolved || !$0.needsAttention }.sorted { $0.createdAt > $1.createdAt }.prefix(25))
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, symbol: String, tint: Color, count: Int, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                SectionLabel(title)
                Text(verbatim: Fmt.digits("\(count)")).font(PDFont.mono(10.5)).foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Theme.track))
            }
            if count == 0 {
                Text(emptyText(title)).font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted).padding(.leading, 19)
            } else {
                VStack(spacing: 10) { content() }.pdGlassContainer(spacing: 10)
            }
        }
    }

    private func emptyText(_ title: String) -> String {
        switch title {
        case "Running": return L("Nothing is syncing right now.")
        case "Needs attention": return L("Nothing needs you. Nice.")
        case "Waiting": return L("No jobs are held back by rules.")
        default: return L("No recent events.")
        }
    }
}

struct ActionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    var action: Action
    var compact = false
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(color.opacity(0.13)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(action.title).font(PDFont.text(14, .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(Fmt.relative(action.createdAt)).font(PDFont.numbers(11)).foregroundStyle(Theme.textMuted)
                    }
                    if !action.message.isEmpty {
                        Text(action.message).font(PDFont.text(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if let job = model.job(action.jobId) { Pill(text: job.name, symbol: "arrow.triangle.2.circlepath") }
                        if let path = action.path {
                            Text(path).font(PDFont.mono(11, .medium)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                        }
                        if action.resolved { Pill(text: L("Resolved"), symbol: "checkmark", color: Brand.green) }
                    }
                }
            }
            if !action.resolved && !action.choices.isEmpty && !compact {
                HStack(spacing: 8) {
                    Spacer()
                    if let path = action.path, let job = model.job(action.jobId) {
                        Button("Show in Finder") {
                            let full = (job.localPath as NSString).appendingPathComponent(path)
                            NSWorkspace.shared.selectFile(FileManager.default.fileExists(atPath: full) ? full : nil, inFileViewerRootedAtPath: job.localPath)
                        }.buttonStyle(.link).font(PDFont.text(12, .semibold))
                    }
                    ForEach(action.choices) { c in
                        let primary = c.id == action.choices.first?.id && c.id != "dismiss"
                        Button {
                            if c.id == "reconnect", let acc = action.data?["accountId"]?.stringValue ?? model.job(action.jobId)?.accountId {
                                router.reconnectAccountID = acc
                                router.show(.accounts)
                                return
                            }
                            busy = c.id
                            Task { await model.resolve(action, choice: c.id); busy = nil }
                        } label: {
                            if busy == c.id { ProgressView().controlSize(.small) } else { Text(c.label) }
                        }
                        .disabled(busy != nil)
                        .modifier(ChoiceStyle(primary: primary))
                    }
                }
            }
        }
        .padding(16)
        .pdGlass(radius: 20, tint: action.resolved || compact ? nil : color)
        .opacity(action.resolved ? 0.75 : 1)
    }

    var color: Color {
        switch action.severity {
        case .error: return Brand.red
        case .warning: return Brand.orange
        case .info: return Brand.cobalt
        }
    }
}

private struct ChoiceStyle: ViewModifier {
    var primary: Bool
    func body(content: Content) -> some View {
        if primary { content.pdPrimary() } else { content.pdSecondary(large: false) }
    }
}
