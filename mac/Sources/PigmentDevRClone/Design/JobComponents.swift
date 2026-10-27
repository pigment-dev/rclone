import RCloneKit
import SwiftUI

/// Progress bar + bytes/total, files/total, speed, ETA and current file.
struct JobProgressBlock: View {
    var progress: SyncProgress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ProgressTrack(fraction: progress.fraction, height: compact ? 5 : 6, indeterminate: progress.isComparing)
            if let part = progress.partLine {
                Text(part).font(PDFont.text(compact ? 10.5 : 11.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            }
            if progress.isComparing {
                Text("Comparing this Mac with the cloud… large folders take a while before files start moving.")
                    .font(PDFont.text(compact ? 10.5 : 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(compact ? 1 : 2)
            } else {
            HStack(spacing: 6) {
                Text(Fmt.bytesOfTotal(progress)).layoutPriority(1)
                Text("·").foregroundStyle(Theme.textMuted)
                Text(compact ? Fmt.percent(progress.fraction * 100) : Fmt.filesOfTotal(progress))
                Spacer(minLength: 6)
                if progress.speed > 0 {
                    if compact { Text(Fmt.speed(progress.speed)) }
                    else { Label(Fmt.speed(progress.speed), systemImage: "speedometer").labelStyle(.titleAndIcon) }
                }
                if let eta = progress.eta, eta > 0 {
                    Text(Fmt.eta(eta) + " " + L("left")).foregroundStyle(Theme.textMuted)
                }
            }
            .font(PDFont.numbers(compact ? 10.5 : 11.5))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            }
            if let file = progress.currentFile {
                HStack(spacing: 5) {
                    Image(systemName: "doc").font(.system(size: 9.5))
                    Text(file).truncationMode(.middle)
                }
                .font(PDFont.text(compact ? 10.5 : 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One job: provider glyph, name, route, status, progress, quick actions.
struct JobRow: View {
    @Environment(AppModel.self) private var model
    var job: Job
    var compact = false
    var showsActions = true

    var body: some View {
        let account = model.account(job.accountId)
        let status = job.status ?? JobStatus()
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 12) {
                ProviderIcon(id: account?.provider ?? "", size: compact ? 28 : 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name.isEmpty ? L("Untitled job") : job.name)
                        .font(PDFont.text(compact ? 13 : 14, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: job.direction.symbol).font(.system(size: 10, weight: .semibold))
                        Text(compact ? remote(account) : route(account))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(PDFont.text(11.5))
                    .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 8)
                if !compact { StatusBadge(label: status.label) }
                if showsActions { actions(status) }
            }
            if let p = status.progress, status.state == .running {
                JobProgressBlock(progress: p, compact: compact)
            } else if compact {
                HStack(spacing: 6) {
                    Image(systemName: status.label.symbol).foregroundStyle(Theme.tone(status.label.tone))
                    Text(status.label.title).foregroundStyle(Theme.textSecondary)
                    if let d = status.label.detail { Text("· " + d).foregroundStyle(Theme.textMuted).lineLimit(1) }
                }
                .font(PDFont.text(11))
            } else if let detail = status.label.detail {
                Text(detail).font(PDFont.text(12)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func remote(_ account: Account?) -> String {
        (account?.name ?? L("Unknown account")) + " · /" + Fmt.remote(job.remotePath)
    }

    private func route(_ account: Account?) -> String {
        let remote = (account?.name ?? L("Unknown account")) + ":" + (job.remotePath.isEmpty ? "/" : Fmt.remote(job.remotePath))
        return Fmt.path(job.localPath) + "  " + (job.direction == .twoWay ? "⇄" : job.direction == .upload ? "→" : "←") + "  " + remote
    }

    @ViewBuilder private func actions(_ status: JobStatus) -> some View {
        HStack(spacing: 6) {
            switch status.state {
            case .running:
                IconButton(symbol: "pause.fill", help: L("Pause")) { Task { await model.pause(job.id) } }
            case .paused:
                IconButton(symbol: "play.fill", help: L("Resume")) { Task { await model.resume(job.id) } }
            case .needsBaseline:
                IconButton(symbol: "arrow.left.arrow.right", help: L("Run baseline")) { Task { await model.run(job.id, resync: true) } }
            default:
                IconButton(symbol: "arrow.clockwise", help: L("Sync now")) { Task { await model.run(job.id) } }
            }
        }
    }
}

/// Summary of overall progress used in the popover header and Dashboard hero.
struct OverallStatusText: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text(text).font(PDFont.text(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }
    var text: String {
        if !model.isConnected { return model.loaded ? L("Sync service offline — reconnecting…") : L("Connecting to the sync service…") }
        let o = model.overall
        let running = max(o.running, model.runningJobs.count)
        if running > 0 {
            var s = o.totalBytes == 0 ? (running == 1 ? L("Checking 1 job for changes") : L("Checking %d jobs for changes", running))
                                      : (running == 1 ? L("Syncing 1 job") : L("Syncing %d jobs", running))
            if o.speed > 0 { s += " · " + Fmt.speed(o.speed) }
            if let eta = o.eta, eta > 0 { s += " · " + Fmt.eta(eta) + " " + L("left") }
            return s
        }
        if model.allPaused {
            if let until = model.pausedUntil { return L("Paused until") + " " + until.formatted(date: .omitted, time: .shortened) }
            return L("Paused")
        }
        if model.attentionCount > 0 { return model.attentionCount == 1 ? L("1 item needs attention") : L("%d items need attention", model.attentionCount) }
        if model.jobs.isEmpty { return L("No sync jobs yet") }
        return L("Everything is up to date")
    }
}

/// Mark used inside the app (not the template menu bar image).
struct BrandMark: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: MenuIconRenderer.image(state: MenuIconState(), rotation: 0, text: nil))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 0.62, height: size * 0.62)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Brand.orange))
            .accessibilityHidden(true)
    }
}
