import XCTest
@testable import RCloneKit

final class FramingTests: XCTestCase {
    func testSplitsLinesAcrossChunks() {
        var f = NDJSONFramer()
        XCTAssertEqual(f.append(Data(#"{"a":1}"#.utf8)), [])
        XCTAssertEqual(f.pendingBytes, 7)
        let lines = f.append(Data("\n{\"b\":2}\r\n\n  \n{\"c\"".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8)! }, [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(f.append(Data(":3}\n".utf8)).map { String(data: $0, encoding: .utf8)! }, [#"{"c":3}"#])
        XCTAssertEqual(f.pendingBytes, 0)
    }

    func testMultipleLinesInOneChunkAndUTF8() {
        var f = NDJSONFramer()
        let lines = f.append(Data("{\"n\":\"Förderung — 文件\"}\n{\"n\":2}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(String(data: lines[0], encoding: .utf8)!.contains("文件"))
    }

    func testDropsRunawayBuffer() {
        var f = NDJSONFramer(maxLineBytes: 10)
        XCTAssertEqual(f.append(Data(String(repeating: "x", count: 50).utf8)), [])
        XCTAssertEqual(f.pendingBytes, 0)
        XCTAssertEqual(f.append(Data("{}\n".utf8)).count, 1)
    }

    func testEncodeAppendsNewline() throws {
        let d = try NDJSONFramer.encode(RPCRequest(id: 1, method: "hello", params: HelloParams(version: "1.0.0")))
        XCTAssertEqual(d.last, 0x0A)
        XCTAssertEqual(d.filter { $0 == 0x0A }.count, 1, "exactly one newline per message")
    }

    func testBackoff() {
        XCTAssertEqual(DaemonClient.backoff(attempt: 1), 0.25)
        XCTAssertEqual(DaemonClient.backoff(attempt: 3), 1)
        XCTAssertEqual(DaemonClient.backoff(attempt: 20), 10)
    }

    func testSocketResolution() {
        XCTAssertEqual(DaemonPaths.resolveSocket(environment: ["PDRCLONE_SOCKET": "/tmp/x.sock"]).path, "/tmp/x.sock")
        XCTAssertEqual(DaemonPaths.resolveSocket(environment: ["PDRCLONE_HOME": "/tmp/h"]).path, "/tmp/h/daemon.sock")
        let def = DaemonPaths.resolveSocket(environment: [:])
        XCTAssertFalse(def.overridden)
        XCTAssertTrue(def.path.hasSuffix("Library/Application Support/PigmentDev rClone/daemon.sock"))
    }
}

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Fmt.bytes(0), "0 B")
        XCTAssertEqual(Fmt.bytes(999), "999 B")
        XCTAssertEqual(Fmt.bytes(1_500), "1.5 KB")
        XCTAssertEqual(Fmt.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(Fmt.bytes(12_345_678_901), "12.3 GB")
        XCTAssertEqual(Fmt.bytes(120_000_000_000), "120 GB")
        XCTAssertEqual(Fmt.bytes(-5), "0 B")
        XCTAssertEqual(Fmt.speed(3_100_000), "3.1 MB/s")
    }

    func testETA() {
        XCTAssertEqual(Fmt.eta(nil), "—")
        XCTAssertEqual(Fmt.eta(-1), "—")
        XCTAssertEqual(Fmt.eta(.infinity), "—")
        XCTAssertEqual(Fmt.eta(8), "8s")
        XCTAssertEqual(Fmt.eta(200), "3m 20s")
        XCTAssertEqual(Fmt.eta(3900), "1h 05m")
        XCTAssertEqual(Fmt.eta(2 * 86400 + 3 * 3600 + 5), "2d 3h")
    }

    func testPercentAndCounts() {
        XCTAssertEqual(Fmt.percent(42.9), "42%")
        XCTAssertEqual(Fmt.percent(140), "100%")
        XCTAssertEqual(Fmt.count(1234567), "1,234,567")
    }

    func testProgressLine() {
        let p = SyncProgress(bytes: 1_200_000_000, totalBytes: 4_000_000_000, files: 120, totalFiles: 900, speed: 3_100_000, eta: 130, percent: 30)
        XCTAssertEqual(Fmt.progressLine(p), "1.2 GB of 4.0 GB · 120 of 900 files · 3.1 MB/s · 2m 10s left")
        XCTAssertEqual(p.fraction, 0.3, accuracy: 0.0001)
        let unknownTotal = SyncProgress(bytes: 5_000, files: 3)
        XCTAssertEqual(Fmt.progressLine(unknownTotal), "5.0 KB · 3 files")
        XCTAssertEqual(SyncProgress(bytes: 50, totalBytes: 200).fraction, 0.25, accuracy: 0.0001, "falls back to bytes when percent is 0")
    }

    func testRelative() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(7200), now: now), "in 2 h")
        XCTAssertEqual(Fmt.relative(Optional<Date>.none, now: now), "—")
    }

    func testStateLabels() {
        XCTAssertEqual(JobStatus(state: .running, progress: SyncProgress(percent: 42)).label.title, "Syncing")
        XCTAssertEqual(JobStatus(state: .running, progress: SyncProgress(percent: 42)).label.detail, "42%")
        XCTAssertEqual(JobStatus(state: .running).label.tone, .active)
        XCTAssertEqual(JobStatus(state: .idle).label.title, "Idle")
        XCTAssertEqual(JobStatus(state: .idle, lastRun: RunSummary(id: "r", startedAt: "2026-10-23T08:00:00Z", ok: true)).label.title, "Up to date")
        XCTAssertEqual(JobStatus(state: .idle, lastRun: RunSummary(id: "r", startedAt: "", ok: false, error: "boom")).label.tone, .danger)
        XCTAssertEqual(JobStatus(state: .waiting, reason: "Wi-Fi only").label.detail, "Wi-Fi only")
        XCTAssertEqual(JobStatus(state: .paused).label.tone, .paused)
        XCTAssertEqual(JobStatus(state: .error, reason: "auth").label.tone, .danger)
        XCTAssertEqual(JobStatus(state: .needsBaseline).label.title, "Needs first sync")
        XCTAssertEqual(JobStatus(state: .queued).label.title, "Queued")
    }
}

final class MenuIconStateTests: XCTestCase {
    func testText() {
        let s = MenuIconState(running: true, percent: 42.7, speed: 3_100_000)
        XCTAssertEqual(s.text(.percent), "42%")
        XCTAssertEqual(s.text(.speed), "3.1 MB/s")
        XCTAssertNil(s.text(.none))
        XCTAssertNil(MenuIconState(running: false, percent: 42).text(.percent), "no text while idle")
        XCTAssertNil(MenuIconState(offline: true, running: true, percent: 42).text(.percent))
    }

    func testQuantisationLimitsRedraws() {
        let a = MenuIconState(running: true, percent: 42.1, speed: 3_101_000).quantised
        let b = MenuIconState(running: true, percent: 42.8, speed: 3_104_000).quantised
        XCTAssertEqual(a, b, "sub-percent changes must not trigger a redraw")
        XCTAssertNotEqual(a, MenuIconState(running: true, percent: 43.0, speed: 3_101_000).quantised)
    }

    func testPauseDurations() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 22, minute: 0))!
        XCTAssertEqual(PauseDuration.oneHour.seconds(now: now, calendar: cal), 3600)
        XCTAssertNil(PauseDuration.untilResumed.seconds(now: now, calendar: cal))
        XCTAssertEqual(PauseDuration.untilTomorrow.seconds(now: now, calendar: cal), 10 * 3600, "until 08:00 next morning")
    }

    @MainActor
    func testModelMenuStateAndEvents() {
        let m = AppModel()
        var job = Job()
        job.id = "j1"; job.name = "A"; job.status = JobStatus(state: .idle)
        m.jobs = [job]
        m.apply(.connection(.connected(HelloResult())))
        XCTAssertFalse(m.menuIconState.running)
        m.apply(.jobProgress(JobProgressNote(jobId: "j1", runId: "r", progress: SyncProgress(bytes: 10, totalBytes: 100, percent: 10))))
        XCTAssertEqual(m.jobs[0].state, .running)
        m.apply(.overall(OverallProgress(running: 1, bytes: 10, totalBytes: 100, percent: 10, speed: 5)))
        XCTAssertTrue(m.menuIconState.running)
        XCTAssertEqual(m.menuIconState.percent, 10)
        m.apply(.jobState(JobStateNote(jobId: "j1", status: JobStatus(state: .idle))))
        m.apply(.overall(OverallProgress()))
        XCTAssertNil(m.jobs[0].progress, "progress is cleared when a run ends")
        XCTAssertFalse(m.menuIconState.running)
        m.apply(.actionNew(Action(id: "a", kind: .conflict, severity: .warning, title: "C", message: "")))
        XCTAssertEqual(m.attentionCount, 1)
        XCTAssertTrue(m.menuIconState.attention)
        var resolved = m.actions[0]; resolved.resolved = true
        m.apply(.actionUpdated(resolved))
        XCTAssertEqual(m.attentionCount, 0)
        m.apply(.jobState(JobStateNote(jobId: "j1", status: JobStatus(state: .paused))))
        XCTAssertTrue(m.menuIconState.paused)
        m.apply(.connection(.disconnected("gone")))
        XCTAssertTrue(m.menuIconState.offline)
    }
}

final class WizardValidationTests: XCTestCase {
    let exists: (String) -> Bool = { $0 == "/Users/a/Projects" }

    func validJob() -> Job {
        var j = Job.draft()
        j.name = "Projects"
        j.accountId = "acc_1"
        j.localPath = "/Users/a/Projects"
        return j
    }

    func testDraftDefaults() {
        let j = Job.draft()
        XCTAssertEqual(j.filters.presets, ["vcs", "ide", "deps", "osjunk"])
        XCTAssertTrue(j.triggers.onChange)
        XCTAssertEqual(j.filters.excludeIfPresent, [".nosync"])
        XCTAssertTrue(j.safety.dryRunFirst)
    }

    func testValidJobPasses() {
        XCTAssertEqual(JobValidator.allIssues(validJob(), fileExists: exists), [])
    }

    func testAccountAndFolder() {
        var j = validJob(); j.accountId = ""
        XCTAssertEqual(JobValidator.issues(for: .account, job: j, fileExists: exists).first?.field, "accountId")
        j = validJob(); j.localPath = ""
        XCTAssertEqual(JobValidator.issues(for: .local, job: j, fileExists: exists).count, 1)
        j.localPath = "relative/path"
        XCTAssertEqual(JobValidator.issues(for: .local, job: j, fileExists: exists).count, 1)
        j.localPath = "/nope"
        XCTAssertEqual(JobValidator.issues(for: .local, job: j, fileExists: exists).count, 1)
        j.localPath = "/"
        XCTAssertEqual(JobValidator.issues(for: .local, job: j, fileExists: { _ in true }).count, 1)
    }

    func testSchedule() {
        var j = validJob()
        j.triggers = Triggers(onChange: false, manual: false)
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j).first?.field, "triggers")
        j.triggers = Triggers(onChange: true, debounceSec: 1)
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j).first?.field, "debounceSec")
        j.triggers = Triggers(onChange: false, daily: "25:00")
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j).first?.field, "daily")
        j.triggers = Triggers(onChange: false, weekly: WeeklyTrigger(day: 8, time: "09:30"))
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j).first?.field, "weekly")
        j.triggers = Triggers(onChange: false, cron: "0 */2 * *")
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j).first?.field, "cron")
        j.triggers = Triggers(onChange: false, intervalMin: 0)
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j).first?.field, "intervalMin")
        j.triggers = Triggers(onChange: true, debounceSec: 10, intervalMin: 60, daily: "09:30", weekly: WeeklyTrigger(day: 1, time: "18:00"), cron: "0 */2 * * *", onWake: true)
        XCTAssertEqual(JobValidator.issues(for: .schedule, job: j), [], "multiple triggers are allowed")
    }

    func testClockAndCron() {
        XCTAssertTrue(JobValidator.isValidClock("09:30"))
        XCTAssertTrue(JobValidator.isValidClock("23:59"))
        XCTAssertFalse(JobValidator.isValidClock("9:30"))
        XCTAssertFalse(JobValidator.isValidClock("24:00"))
        XCTAssertTrue(JobValidator.isValidCron("0 */2 * * *"))
        XCTAssertTrue(JobValidator.isValidCron("@daily"))
        XCTAssertTrue(JobValidator.isValidCron("30 9 * * MON-FRI"))
        XCTAssertFalse(JobValidator.isValidCron("@sometimes"))
        XCTAssertFalse(JobValidator.isValidCron("* * * *"))
    }

    func testOtherSteps() {
        var j = validJob()
        j.deletePolicy = .archive; j.archiveRetentionDays = 0
        XCTAssertEqual(JobValidator.issues(for: .direction, job: j).first?.field, "archiveRetentionDays")
        j = validJob(); j.filters.rules = [FilterRule(kind: .exclude, pattern: "  ")]
        XCTAssertEqual(JobValidator.issues(for: .exclusions, job: j).first?.field, "rules")
        j = validJob(); j.network.ssidAllow = ["Home"]; j.network.ssidDeny = ["Home"]
        XCTAssertEqual(JobValidator.issues(for: .network, job: j).first?.field, "ssid")
        j = validJob(); j.network.minBatteryPercent = 0
        XCTAssertEqual(JobValidator.issues(for: .network, job: j).first?.field, "minBatteryPercent")
        j = validJob(); j.name = " "
        XCTAssertEqual(JobValidator.issues(for: .preview, job: j).first?.field, "name")
    }

    func testFlowsAndNames() {
        XCTAssertEqual(WizardStep.flow(firstRun: true).first, .welcome)
        XCTAssertEqual(WizardStep.flow(firstRun: false).first, .account)
        XCTAssertEqual(WizardStep.flow(firstRun: false).last, .done)
        XCTAssertEqual(JobValidator.suggestedName(localPath: "/Users/a/Projects", accountName: "Work Drive"), "Projects → Work Drive")
    }
}

final class BandwidthGridTests: XCTestCase {
    func testSlotsRoundTrip() {
        var g = BandwidthGrid(upKBps: 512, downKBps: nil)
        for d in 1...5 { for h in 9..<18 { g.set(day: d, hour: h, true) } }
        g.set(day: 6, hour: 22, true); g.set(day: 6, hour: 23, true)
        let slots = g.slots
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots[0], BandwidthSlot(days: [1, 2, 3, 4, 5], from: "09:00", to: "18:00", upKBps: 512, downKBps: nil))
        XCTAssertEqual(slots[1].to, "24:00")
        XCTAssertEqual(BandwidthGrid(slots: slots), g)
    }

    func testEmpty() {
        XCTAssertEqual(BandwidthGrid().slots, [])
    }
}

final class FilterEvaluatorTests: XCTestCase {
    func testPresetsAndRules() {
        let f = Filters(presets: ["vcs", "deps", "osjunk", "ide"], rules: [FilterRule(kind: .include, pattern: "vendor/keep/**"), FilterRule(kind: .exclude, pattern: "*.log")])
        XCTAssertFalse(FilterEvaluator.explain("app/.git/config", filters: f).included)
        XCTAssertEqual(FilterEvaluator.explain("app/.git/config", filters: f).rule, "- .git/** (vcs)")
        XCTAssertFalse(FilterEvaluator.explain("web/node_modules/react/index.js", filters: f).included)
        XCTAssertFalse(FilterEvaluator.explain("Photos/.DS_Store", filters: f).included)
        XCTAssertFalse(FilterEvaluator.explain(".claude/settings.json", filters: f).included)
        XCTAssertFalse(FilterEvaluator.explain("logs/server.log", filters: f).included)
        XCTAssertTrue(FilterEvaluator.explain("vendor/keep/lib.php", filters: f).included, "include rules override presets")
        XCTAssertFalse(FilterEvaluator.explain("vendor/other/lib.php", filters: f).included)
        XCTAssertTrue(FilterEvaluator.explain("src/main.swift", filters: f).included)
        XCTAssertNil(FilterEvaluator.explain("src/main.swift", filters: f).rule)
    }

    func testGlobSemantics() {
        XCTAssertTrue(FilterEvaluator.matches("*.log", path: "a/b/c.log"))
        XCTAssertFalse(FilterEvaluator.matches("/*.log", path: "a/c.log"), "leading slash anchors to root")
        XCTAssertTrue(FilterEvaluator.matches("/*.log", path: "c.log"))
        XCTAssertFalse(FilterEvaluator.matches("a*.txt", path: "abc/x.txt"), "* stays within a segment")
        XCTAssertTrue(FilterEvaluator.matches("file?.txt", path: "file1.txt"))
        XCTAssertTrue(FilterEvaluator.matches("._*", path: "x/._thing"))
    }

    func testGitignoreImport() {
        let rules = FilterEvaluator.rules(fromGitignore: "# comment\nnode_modules/\n*.log\n!important.log\n\n")
        XCTAssertEqual(rules, [FilterRule(kind: .exclude, pattern: "node_modules/**"), FilterRule(kind: .exclude, pattern: "*.log"), FilterRule(kind: .include, pattern: "important.log")])
    }
}
