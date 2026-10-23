import XCTest
@testable import RCloneKit

/// Codable round-trips for every protocol type, using samples shaped exactly like docs/PROTOCOL.md.
final class ProtocolModelTests: XCTestCase {
    func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let a = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(a)
        let b = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(a, b, "round-trip changed \(T.self)", file: file, line: line)
        return a
    }

    func testHelloAndDaemonInfo() throws {
        let h = try roundTrip(HelloResult.self, #"{"daemonVersion":"1.0.0","rcloneVersion":"v1.75.0","protocol":1,"os":"darwin","arch":"arm64","dataDir":"/Users/a/Library/Application Support/PigmentDev rClone","pid":4242,"startedAt":"2026-10-23T08:00:00Z"}"#)
        XCTAssertEqual(h.protocol, 1)
        XCTAssertEqual(h.pid, 4242)
        let i = try roundTrip(DaemonInfo.self, #"{"daemonVersion":"1.0.0","rcloneVersion":"v1.75.0","protocol":1,"os":"darwin","arch":"arm64","dataDir":"/x","pid":1,"startedAt":"2026-10-23T08:00:00Z","jobsRunning":2,"uptimeSec":3600,"rssBytes":31000000,"goroutines":42}"#)
        XCTAssertEqual(i.jobsRunning, 2)
        XCTAssertEqual(i.rssBytes, 31_000_000)
    }

    func testSystemStateEncodesExplicitNulls() throws {
        let s = try roundTrip(SystemState.self, #"{"network":{"status":"satisfied","interface":"wifi","expensive":false,"constrained":false,"ssid":"Home","vpn":false},"power":{"onBattery":true,"batteryPercent":64,"lowPowerMode":false},"disk":{"freeBytes":120000000000},"sleeping":false}"#)
        XCTAssertEqual(s.network.ssid, "Home")
        XCTAssertEqual(s.power.batteryPercent, 64)
        var t = s
        t.network.ssid = nil
        t.power.batteryPercent = nil
        let json = String(data: try JSONEncoder.rpc.encode(t), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""ssid":null"#), json)
        XCTAssertTrue(json.contains(#""batteryPercent":null"#), json)
    }

    func testProviderAndField() throws {
        let p = try roundTrip(Provider.self, #"{"id":"drive","name":"Google Drive","auth":"oauth","category":"cloud","popular":true,"fields":[{"name":"scope","label":"Scope","help":"","type":"select","required":false,"default":"drive","options":[{"value":"drive","label":"Full"}],"advanced":false},{"name":"port","label":"Port","help":"","type":"int","required":false,"default":22,"options":[],"advanced":true}]}"#)
        XCTAssertEqual(p.auth, .oauth)
        XCTAssertEqual(p.fields.count, 2)
        XCTAssertEqual(p.fields[0].type, .select)
        XCTAssertEqual(p.fields[0].default?.stringValue, "drive")
        XCTAssertEqual(p.fields[1].default?.stringValue, "22")
        let list = try JSONDecoder().decode(ProvidersResult.self, from: Data(#"{"providers":[{"id":"s3","name":"S3","auth":"fields","category":"object","popular":true,"fields":null}]}"#.utf8))
        XCTAssertEqual(list.providers.first?.fields, [])
    }

    func testAccount() throws {
        let a = try roundTrip(Account.self, #"{"id":"acc_x1y2z3","provider":"drive","name":"Work","remote":"pd_acc_x1y2z3","status":"needsAuth","error":"token expired","createdAt":"2026-10-23T08:00:00Z","quota":{"total":100,"used":25,"free":75,"trashed":null}}"#)
        XCTAssertEqual(a.status, .needsAuth)
        XCTAssertEqual(a.quota?.usedFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertNil(a.quota?.trashed)
        let noQuota = try roundTrip(Account.self, #"{"id":"a","provider":"sftp","name":"Box","remote":"r","status":"ok","error":null,"createdAt":"2026-10-23T08:00:00Z","quota":null}"#)
        XCTAssertNil(noQuota.quota)
    }

    func testAddAccountStates() throws {
        let done = try roundTrip(AddAccountResult.self, #"{"state":"done","account":{"id":"acc_1","provider":"s3","name":"B","remote":"pd_acc_1","status":"ok","error":null,"createdAt":"2026-10-23T08:00:00Z","quota":null}}"#)
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.account?.id, "acc_1")
        let oauth = try roundTrip(AddAccountResult.self, #"{"state":"needsOAuth","sessionId":"s1","authUrl":"http://127.0.0.1:53682/auth?state=x"}"#)
        XCTAssertEqual(oauth.state, .needsOAuth)
        XCTAssertEqual(oauth.authUrl, "http://127.0.0.1:53682/auth?state=x")
        let input = try roundTrip(AddAccountResult.self, #"{"state":"needsInput","sessionId":"s2","question":{"name":"team_drive","label":"Shared Drive","help":"Pick one","type":"select","options":[{"value":"0A1","label":"Design"}],"default":""}}"#)
        XCTAssertEqual(input.question?.options.first?.label, "Design")
        XCTAssertEqual(input.question?.asField.type, .select)
        // continue params encode answer:null for OAuth polling
        let json = String(data: try JSONEncoder.rpc.encode(AddAccountContinueParams(sessionId: "s1")), encoding: .utf8)!
        XCTAssertEqual(json, #"{"answer":null,"sessionId":"s1"}"#)
    }

    func testRemoteList() throws {
        let r = try JSONDecoder().decode(RemoteListResult.self, from: Data(#"{"path":"Backups","entries":[{"name":"Projects","path":"Backups/Projects","isDir":true,"size":0,"modTime":"2026-10-23T08:00:00Z"}]}"#.utf8))
        XCTAssertEqual(r.entries.first?.isDir, true)
        let p = String(data: try JSONEncoder.rpc.encode(RemoteListParams(accountId: nil, path: "")), encoding: .utf8)!
        XCTAssertEqual(p, #"{"accountId":null,"dirsOnly":true,"path":""}"#)
    }

    static let jobJSON = #"""
    {"id":"job_8f3k2m","name":"Projects","enabled":true,"localPath":"/Users/a/Projects","accountId":"acc_x1y2z3","remotePath":"Backups/Projects",
     "direction":"twoWay","deletePolicy":"archive","archiveRetentionDays":30,"conflictPolicy":"ask",
     "filters":{"presets":["vcs","ide","deps","build","osjunk","caches","dotfolders","dotfiles"],"rules":[{"kind":"exclude","pattern":"*.log"},{"kind":"include","pattern":"keep/**"}],"maxSizeMB":null,"minAgeSec":5,"excludeIfPresent":[".nosync"],"respectGitignore":true,"skipSymlinks":false},
     "triggers":{"onChange":true,"debounceSec":10,"intervalMin":null,"daily":"09:30","weekly":{"day":1,"time":"09:30"},"cron":"0 */2 * * *","onWake":true,"manual":true},
     "network":{"allowCellular":false,"allowExpensive":false,"wifiOnly":true,"ssidAllow":["Home"],"ssidDeny":["Cafe"],"pauseOnBattery":true,"minBatteryPercent":20},
     "limits":{"bwUpKBps":null,"bwDownKBps":2048,"transfers":4,"checkers":8},
     "safety":{"maxDeletePercent":25,"dryRunFirst":true,"checksum":false},
     "createdAt":"2026-10-23T08:00:00Z","updatedAt":"2026-10-23T09:00:00.123456789Z",
     "status":{"state":"running","reason":null,
       "lastRun":{"id":"run_1","startedAt":"2026-10-23T07:00:00Z","endedAt":"2026-10-23T07:05:00Z","ok":true,"error":null,"bytes":1000,"files":10,"deletes":0,"conflicts":1,"dryRun":false},
       "nextRun":"2026-10-23T11:00:00Z",
       "progress":{"bytes":500,"totalBytes":2000,"files":3,"totalFiles":12,"speed":1048576,"eta":42,"percent":25.0,"checks":10,"totalChecks":20,"errors":0,
         "transferring":[{"name":"src/a.swift","size":100,"bytes":50,"percent":50,"speed":1000}]}}}
    """#

    func testJobFull() throws {
        let j = try roundTrip(Job.self, Self.jobJSON)
        XCTAssertEqual(j.id, "job_8f3k2m")
        XCTAssertEqual(j.direction, .twoWay)
        XCTAssertEqual(j.conflictPolicy, .ask)
        XCTAssertEqual(j.filters.rules[1].kind, .include)
        XCTAssertNil(j.filters.maxSizeMB)
        XCTAssertEqual(j.triggers.weekly?.day, 1)
        XCTAssertEqual(j.triggers.cron, "0 */2 * * *")
        XCTAssertEqual(j.network.minBatteryPercent, 20)
        XCTAssertEqual(j.limits.bwDownKBps, 2048)
        XCTAssertEqual(j.state, .running)
        XCTAssertEqual(j.progress?.transferring.first?.name, "src/a.swift")
        XCTAssertEqual(j.progress?.eta, 42)
        XCTAssertEqual(j.status?.lastRun?.conflicts, 1)
        XCTAssertNotNil(RFC3339.date(j.updatedAt), "fractional-second timestamps must parse")
    }

    func testJobLenientDecoding() throws {
        // Go encodes nil slices as null and the daemon may omit sections or send new enum values.
        let j = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"job_1","name":"N","direction":"sideways","filters":{"presets":null,"rules":null},"status":{"state":"hibernating"}}"#.utf8))
        XCTAssertEqual(j.direction, .upload)
        XCTAssertEqual(j.filters.presets, [])
        XCTAssertEqual(j.state, .idle)
        XCTAssertEqual(j.limits.transfers, 4)
        XCTAssertEqual(j.triggers.debounceSec, 10)
        XCTAssertEqual(j.safety.maxDeletePercent, 25)
    }

    func testJobSpecOmitsIdAndStatusButKeepsNulls() throws {
        let j = try JSONDecoder().decode(Job.self, from: Data(Self.jobJSON.utf8))
        let data = try JSONEncoder.rpc.encode(CreateJobParams(job: JobSpec(j)))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let job = obj["job"] as! [String: Any]
        XCTAssertNil(job["id"])
        XCTAssertNil(job["status"])
        XCTAssertNil(job["createdAt"])
        let triggers = job["triggers"] as! [String: Any]
        XCTAssertTrue(triggers["intervalMin"] is NSNull, "nullable fields must encode as explicit null")
        XCTAssertEqual(triggers["daily"] as? String, "09:30")
        let filters = job["filters"] as! [String: Any]
        XCTAssertTrue(filters["maxSizeMB"] is NSNull)
        let back = try JSONDecoder().decode(JobSpec.self, from: try JSONSerialization.data(withJSONObject: job))
        XCTAssertEqual(back, JobSpec(j))
    }

    func testRunAndHistory() throws {
        let r = try roundTrip(RunSummary.self, #"{"id":"run_9","startedAt":"2026-10-23T07:00:00Z","endedAt":null,"ok":false,"error":"quota exceeded","bytes":0,"files":0,"deletes":0,"conflicts":0,"dryRun":true}"#)
        XCTAssertFalse(r.ok)
        XCTAssertNil(r.endedAt)
        let h = try JSONDecoder().decode(HistoryResult.self, from: Data(#"{"runs":[{"id":"run_1","startedAt":"2026-10-23T07:00:00Z","ok":true}]}"#.utf8))
        XCTAssertEqual(h.runs.count, 1)
    }

    func testPreviewSyncAndAsync() throws {
        let p = try roundTrip(PreviewResult.self, #"{"adds":3,"updates":1,"deletes":2,"excluded":40,"bytes":12345,"sample":{"adds":["a"],"updates":["b"],"deletes":["c","d"],"excluded":[{"path":".git/HEAD","rule":"- .git/**"}]}}"#)
        XCTAssertFalse(p.isPending)
        XCTAssertEqual(p.sample.excluded.first?.rule, "- .git/**")
        let pending = try JSONDecoder().decode(PreviewResult.self, from: Data(#"{"runId":"run_p"}"#.utf8))
        XCTAssertTrue(pending.isPending)
        let byID = String(data: try JSONEncoder.rpc.encode(PreviewParams.id("job_1")), encoding: .utf8)!
        XCTAssertEqual(byID, #"{"id":"job_1"}"#)
    }

    func testExplainRunPauseParams() throws {
        _ = try roundTrip(ExplainResult.self, #"{"included":false,"rule":"- node_modules/**"}"#)
        XCTAssertEqual(String(data: try JSONEncoder.rpc.encode(RunJobParams(id: "j", dryRun: true)), encoding: .utf8)!, #"{"dryRun":true,"id":"j","resync":false}"#)
        XCTAssertEqual(String(data: try JSONEncoder.rpc.encode(PauseAllParams(untilSec: nil)), encoding: .utf8)!, #"{"untilSec":null}"#)
        XCTAssertEqual(String(data: try JSONEncoder.rpc.encode(PauseAllParams(untilSec: 3600)), encoding: .utf8)!, #"{"untilSec":3600}"#)
    }

    func testAction() throws {
        let a = try roundTrip(Action.self, #"{"id":"act_1","jobId":"job_1","kind":"conflict","severity":"warning","title":"Conflict","message":"Both changed","path":"a/b.txt","createdAt":"2026-10-23T08:00:00Z","resolved":false,"choices":[{"id":"keepLocal","label":"Keep local"},{"id":"keepRemote","label":"Keep remote"},{"id":"keepBoth","label":"Keep both"}]}"#)
        XCTAssertEqual(a.kind, .conflict)
        XCTAssertEqual(a.choices.map(\.id), ["keepLocal", "keepRemote", "keepBoth"])
        XCTAssertTrue(a.needsAttention)
        let info = try roundTrip(Action.self, #"{"id":"act_2","jobId":null,"kind":"info","severity":"info","title":"Done","message":"","path":null,"createdAt":"2026-10-23T08:00:00Z","resolved":false,"choices":[]}"#)
        XCTAssertFalse(info.needsAttention)
    }

    func testLogLine() throws {
        let l = try roundTrip(LogLine.self, #"{"ts":"2026-10-23T08:00:00Z","level":"warn","jobId":"job_1","runId":"run_1","msg":"Skipped","path":"x/y"}"#)
        XCTAssertEqual(l.level, .warn)
        XCTAssertTrue(LogLine.Level.error > .warn)
        let q = String(data: try JSONEncoder.rpc.encode(LogQueryParams(level: "info")), encoding: .utf8)!
        XCTAssertEqual(q, #"{"level":"info","limit":500}"#)
    }

    func testSettings() throws {
        let s = try roundTrip(DaemonSettings.self, #"{"defaults":{"direction":"upload","conflictPolicy":"keepBoth","deletePolicy":"archive","debounceSec":10,"minAgeSec":0,"maxDeletePercent":25,"dryRunFirst":true,"presets":["vcs","ide"]},"network":{"allowCellular":false,"allowExpensive":false,"bwSchedule":[{"days":[1,2,3,4,5],"from":"09:00","to":"18:00","upKBps":512,"downKBps":null}],"proxy":null},"logs":{"level":"info","retentionDays":30},"engine":{"transfers":4,"checkers":8,"tpsLimit":0}}"#)
        XCTAssertEqual(s.network.bwSchedule.first?.days, [1, 2, 3, 4, 5])
        XCTAssertNil(s.network.bwSchedule.first?.downKBps)
        XCTAssertEqual(s.defaults.presets, ["vcs", "ide"])
        let empty = try JSONDecoder().decode(DaemonSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.engine.transfers, 4)
        XCTAssertEqual(empty.logs.retentionDays, 30)
    }

    func testDedupe() throws {
        let r = try JSONDecoder().decode(DedupeScanResult.self, from: Data(#"{"groups":[{"name":"a.txt","files":[{"id":"1","path":"a.txt","size":1,"modTime":"2026-10-23T08:00:00Z"},{"id":"2","path":"a.txt","size":2,"modTime":"2026-10-23T08:00:00Z"}]}]}"#.utf8))
        XCTAssertEqual(r.groups.first?.files.count, 2)
    }

    func testNotifications() throws {
        func event(_ line: String) -> DaemonEvent? {
            let data = Data(line.utf8)
            let head = try! JSONDecoder().decode(RPCHead.self, from: data)
            return DaemonEvent.decode(method: head.method!, line: data)
        }
        guard case .jobState(let s)? = event(#"{"jsonrpc":"2.0","method":"job.state","params":{"jobId":"job_1","status":{"state":"waiting","reason":"Wi-Fi only","lastRun":null,"nextRun":null,"progress":null}}}"#) else { return XCTFail() }
        XCTAssertEqual(s.status.reason, "Wi-Fi only")
        guard case .jobProgress(let p)? = event(#"{"jsonrpc":"2.0","method":"job.progress","params":{"jobId":"job_1","runId":"run_1","progress":{"bytes":1,"totalBytes":4,"files":0,"totalFiles":1,"speed":10,"eta":null,"percent":25,"checks":0,"totalChecks":0,"errors":0,"transferring":[]}}}"#) else { return XCTFail() }
        XCTAssertEqual(p.progress.percent, 25)
        guard case .overall(let o)? = event(#"{"jsonrpc":"2.0","method":"overall.progress","params":{"running":2,"bytes":10,"totalBytes":40,"percent":25,"speed":99.5,"eta":30}}"#) else { return XCTFail() }
        XCTAssertEqual(o.running, 2)
        guard case .actionNew(let a)? = event(#"{"jsonrpc":"2.0","method":"action.new","params":{"action":{"id":"act_1","kind":"quotaFull","severity":"error","title":"Full","message":"","createdAt":"2026-10-23T08:00:00Z","resolved":false,"choices":[]}}}"#) else { return XCTFail() }
        XCTAssertEqual(a.kind, .quotaFull)
        guard case .actionUpdated? = event(#"{"jsonrpc":"2.0","method":"action.updated","params":{"action":{"id":"act_1","resolved":true}}}"#) else { return XCTFail() }
        guard case .logLine(let l)? = event(#"{"jsonrpc":"2.0","method":"log.line","params":{"line":{"ts":"2026-10-23T08:00:00Z","level":"info","jobId":null,"runId":null,"msg":"hi","path":null}}}"#) else { return XCTFail() }
        XCTAssertEqual(l.msg, "hi")
        guard case .health(let h)? = event(#"{"jsonrpc":"2.0","method":"daemon.health","params":{"ok":false,"message":"disk full"}}"#) else { return XCTFail() }
        XCTAssertFalse(h.ok)
        guard case .other(let m)? = event(#"{"jsonrpc":"2.0","method":"future.thing","params":{}}"#) else { return XCTFail() }
        XCTAssertEqual(m, "future.thing")
    }

    func testEnvelopes() throws {
        let req = String(data: try JSONEncoder.rpc.encode(RPCRequest(id: 7, method: "jobs.list", params: EmptyParams())), encoding: .utf8)!
        XCTAssertEqual(req, #"{"id":7,"jsonrpc":"2.0","method":"jobs.list","params":{}}"#)
        let err = try JSONDecoder().decode(RPCHead.self, from: Data(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"bad","data":{"field":"x"}}}"#.utf8))
        XCTAssertEqual(err.id, 7)
        XCTAssertEqual(err.error?.code, RPCErrorPayload.invalidParams)
        XCTAssertEqual(err.error?.data?["field"]?.stringValue, "x")
        let stringID = try JSONDecoder().decode(RPCHead.self, from: Data(#"{"jsonrpc":"2.0","id":"8","result":{}}"#.utf8))
        XCTAssertEqual(stringID.id, 8)
    }

    func testJSONValue() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,2.5,"x",true,null]}"#.utf8))
        let back = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(v))
        XCTAssertEqual(v, back)
        XCTAssertEqual(String(data: try JSONEncoder().encode(JSONValue.number(3)), encoding: .utf8), "3")
    }
}
