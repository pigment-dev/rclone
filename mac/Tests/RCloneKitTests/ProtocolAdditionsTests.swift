import XCTest
@testable import RCloneKit

/// Fields/methods the Go daemon added on top of PROTOCOL.md v1 (nothing renamed).
final class ProtocolAdditionsTests: XCTestCase {
    func testHelloDemoAndUnknownKeys() throws {
        let h = try JSONDecoder().decode(HelloResult.self, from: Data(#"{"daemonVersion":"1","protocol":1,"demo":true,"somethingNew":{"x":1}}"#.utf8))
        XCTAssertTrue(h.demo)
        XCTAssertFalse(try JSONDecoder().decode(HelloResult.self, from: Data("{}".utf8)).demo)
    }

    func testFieldProviderAndActionData() throws {
        let f = try JSONDecoder().decode(Field.self, from: Data(#"{"name":"region","label":"Region","type":"string","provider":"AWS"}"#.utf8))
        XCTAssertEqual(f.provider, "AWS")
        let a = try JSONDecoder().decode(Action.self, from: Data(#"{"id":"act_1","kind":"authExpired","severity":"error","title":"t","message":"m","createdAt":"2026-10-23T08:00:00Z","resolved":false,"choices":[{"id":"reconnect","label":"Reconnect"}],"data":{"accountId":"acc_1"}}"#.utf8))
        XCTAssertEqual(a.data?["accountId"]?.stringValue, "acc_1")
    }

    func testEngineMemoryLimitAndDismissAll() throws {
        let s = try JSONDecoder().decode(DaemonSettings.self, from: Data(#"{"engine":{"transfers":4,"checkers":8,"tpsLimit":0,"memoryLimitMB":200}}"#.utf8))
        XCTAssertEqual(s.engine.memoryLimitMB, 200)
        let json = String(data: try JSONEncoder.rpc.encode(s), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""memoryLimitMB":200"#), "round-trips so settings.set doesn't drop it")
        XCTAssertEqual(try JSONDecoder().decode(DismissAllResult.self, from: Data(#"{"count":3}"#.utf8)).count, 3)
    }

    func testJobPreviewNotificationShape() throws {
        let line = Data(#"{"jsonrpc":"2.0","method":"job.preview","params":{"jobId":"job_1","preview":{"adds":2,"updates":0,"deletes":1,"excluded":5,"bytes":10,"sample":{"adds":["a","b"]}}}}"#.utf8)
        guard case .preview(let p)? = DaemonEvent.decode(method: "job.preview", line: line) else { return XCTFail() }
        XCTAssertEqual(p.jobId, "job_1")
        XCTAssertEqual(p.result?.adds, 2)
        XCTAssertEqual(p.result?.sample.adds, ["a", "b"])
    }

    func testConfigBundleIsLenient() throws {
        let b = try JSONDecoder().decode(ConfigBundle.self, from: Data(#"{"settings":null,"jobs":[{"id":"job_1","name":"P","localPath":"/x","accountId":"acc","status":{"state":"idle"}}]}"#.utf8))
        XCTAssertEqual(b.jobs.first?.name, "P")
        XCTAssertEqual(b.jobs.first?.limits.transfers, 4)
    }

    func testAddAccountNeedsInputThenOAuth() throws {
        // Drive asks a question before OAuth; both must decode into the same result shape.
        let q = try JSONDecoder().decode(AddAccountResult.self, from: Data(#"{"state":"needsInput","sessionId":"s","question":{"name":"config_client_id_ok","label":"Use rclone's shared client?","type":"bool","default":true}}"#.utf8))
        XCTAssertEqual(q.state, .needsInput)
        XCTAssertEqual(q.question?.type, .bool)
        XCTAssertEqual(q.question?.default?.stringValue, "true")
    }
}
