import Charts
import RCloneKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Page {
            PageHeader(title: "Dashboard", subtitle: greeting) {
                Button { router.addJob() } label: { Label("New job", systemImage: "plus") }
                    .pdPrimary()
                    .disabled(!model.isConnected)
            }
            hero
            statTiles
            HStack(alignment: .top, spacing: 18) {
                activity.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    storage
                    upcoming
                }
                .frame(width: 330)
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning. Here's how your folders are doing." : h < 18 ? "Good afternoon. Here's how your folders are doing." : "Good evening. Here's how your folders are doing."
    }

    // MARK: Hero

    private var hero: some View {
        let state = model.menuIconState
        return HStack(spacing: 26) {
            ProgressRing(fraction: state.running ? (state.percent ?? 0) / 100 : 1, running: state.running, attention: state.attention && !state.running, offline: !model.isConnected)
                .frame(width: 108, height: 108)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(state.running ? "Syncing now" : model.isConnected ? "Status" : "Offline")
                Text(heroTitle)
                    .font(PDFont.display(28, .black))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                OverallStatusText()
                if state.running {
                    HStack(spacing: 18) {
                        Metric(value: Fmt.speed(model.overall.speed), label: "Speed")
                        Metric(value: Fmt.bytes(model.overall.bytes) + " / " + Fmt.bytes(model.overall.totalBytes), label: "Transferred")
                        Metric(value: Fmt.eta(model.overall.eta), label: "Remaining")
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdGlass(radius: Theme.cardRadius, tint: state.running ? Brand.orange : nil)
    }

    private var heroTitle: String {
        let s = model.menuIconState
        if !model.isConnected { return L("Reconnecting to the sync service") }
        if s.running { return s.percent.map { Fmt.percent($0) + " " + L("done") } ?? L("Syncing") }
        if model.allPaused { return L("Syncing is paused") }
        if model.attentionCount > 0 { return L("A few things need you") }
        if model.jobs.isEmpty { return L("Let's sync your first folder") }
        return L("All folders are in sync")
    }

    // MARK: Tiles

    private var statTiles: some View {
        let syncedToday = model.jobs.compactMap { $0.status?.lastRun }.filter { r in
            RFC3339.date(r.endedAt ?? r.startedAt).map { Calendar.current.isDateInToday($0) } ?? false
        }
        let bytesToday = syncedToday.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: 14) {
            StatTile(symbol: "arrow.triangle.2.circlepath", value: "\(model.jobs.count)", label: "Sync jobs", tint: Brand.orange)
            StatTile(symbol: "bolt.fill", value: "\(max(model.overall.running, model.runningJobs.count))", label: "Running", tint: Brand.cobalt)
            StatTile(symbol: "checkmark.icloud.fill", value: Fmt.bytes(bytesToday), label: "Synced today", tint: Brand.green)
            StatTile(symbol: "bell.badge.fill", value: "\(model.attentionCount)", label: "Need attention", tint: model.attentionCount > 0 ? Brand.orange : Theme.textMuted)
                .onTapGesture { router.show(.actions) }
        }
        .pdGlassContainer(spacing: 14)
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel("Throughput")
                        Spacer()
                        Text(Fmt.speed(model.overall.speed)).font(PDFont.numbers(12, .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    SpeedChart(samples: model.speedHistory)
                        .frame(height: 120)
                }
            }
            HStack {
                SectionLabel("Jobs")
                Spacer()
                Button("See all") { router.show(.jobs) }.buttonStyle(.link).font(PDFont.text(12, .semibold))
            }
            if model.jobs.isEmpty {
                GlassCard {
                    EmptyState(symbol: "folder.badge.plus", title: "No sync jobs yet", message: "Pick a folder on this Mac and a place in the cloud. We'll keep them in sync — and skip .git, node_modules and other clutter.")
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(model.jobs.prefix(6)) { job in
                        JobRow(job: job)
                            .padding(16)
                            .pdGlass(radius: 20, interactive: true)
                            .onTapGesture { router.show(.jobs, job: job.id) }
                    }
                }
                .pdGlassContainer(spacing: 10)
            }
        }
    }

    // MARK: Side column

    private var storage: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Storage")
                if model.accounts.isEmpty {
                    Text("No accounts connected").font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted)
                }
                ForEach(model.accounts) { acc in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProviderIcon(id: acc.provider, size: 24)
                            Text(acc.name).font(PDFont.text(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            if let q = acc.quota, let used = q.used {
                                Text(Fmt.bytes(used) + (q.total.map { " / " + Fmt.bytes($0) } ?? ""))
                                    .font(PDFont.numbers(11)).foregroundStyle(Theme.textMuted)
                            }
                        }
                        if let f = acc.quota?.usedFraction {
                            ProgressTrack(fraction: f, tint: f > 0.9 ? Brand.red : ProviderIcon(id: acc.provider).color, height: 5)
                        }
                    }
                }
            }
        }
    }

    private var upcoming: some View {
        let next = model.jobs.compactMap { j -> (Job, Date)? in
            guard let d = RFC3339.date(j.status?.nextRun) else { return nil }
            return (j, d)
        }.sorted { $0.1 < $1.1 }.prefix(5)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Upcoming")
                if next.isEmpty {
                    Text("Jobs that run on change start as soon as files change.").font(PDFont.text(12.5)).foregroundStyle(Theme.textMuted)
                }
                ForEach(Array(next), id: \.0.id) { job, date in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(Brand.cobalt).font(.system(size: 11, weight: .semibold))
                        Text(job.name).font(PDFont.text(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(Fmt.relative(date)).font(PDFont.numbers(11.5)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }
}

struct Metric: View {
    var value: String
    var label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(PDFont.numbers(14, .semibold)).foregroundStyle(Theme.text)
            SectionLabel(label)
        }
    }
}

struct StatTile: View {
    var symbol: String
    var value: String
    var label: String
    var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.13)))
            Text(value).font(PDFont.display(24, .heavy)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
            SectionLabel(label)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdGlass(radius: 22)
        .accessibilityElement(children: .combine)
    }
}

/// Large ring used in the Dashboard hero.
struct ProgressRing: View {
    var fraction: Double
    var running: Bool
    var attention: Bool
    var offline: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityHidden(true)
    }
    var color: Color { offline ? Theme.textMuted : attention ? Brand.orange : running ? Brand.orange : Brand.green }
    var symbol: String { offline ? "bolt.horizontal.circle" : running ? "arrow.triangle.2.circlepath" : attention ? "exclamationmark" : "checkmark" }
}

struct SpeedChart: View {
    var samples: [AppModel.SpeedSample]
    var body: some View {
        if samples.count < 2 {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Theme.track.opacity(0.6))
                Text("Speed appears here while syncing").font(PDFont.text(12)).foregroundStyle(Theme.textMuted)
            }
        } else {
            Chart(samples) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Speed", s.speed))
                    .foregroundStyle(Brand.orange.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.speed))
                    .foregroundStyle(Brand.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.5))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.speed(d)).font(PDFont.numbers(9.5)) } }
                }
            }
        }
    }
}
