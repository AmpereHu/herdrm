import XCTest
@testable import HerdrKit

/// Wire-format tests: no herdr server, no socket, no network. These are the tests that
/// catch a renamed JSON key or a broken envelope before a release does.
final class WireFormatTests: XCTestCase {

    // MARK: - Requests

    func testRequestIsNewlineTerminatedJSON() throws {
        let data = SocketRPC.encodeRequest(id: "abc", method: "ping", params: .object([:]))
        XCTAssertEqual(data.last, 0x0A, "NDJSON frames must end with a newline")

        let value = try JSONDecoder().decode(JSONValue.self, from: data.dropLast())
        XCTAssertEqual(value["id"]?.stringValue, "abc")
        XCTAssertEqual(value["method"]?.stringValue, "ping")
        XCTAssertEqual(value["params"], JSONValue.object([:]))
    }

    /// herdr rejects a request whose `params` is absent, so nil must encode as `{}`.
    func testNilParamsEncodesAsEmptyObject() throws {
        let data = SocketRPC.encodeRequest(id: "1", method: "session.snapshot", params: nil)
        let value = try JSONDecoder().decode(JSONValue.self, from: data.dropLast())
        XCTAssertEqual(value["params"], JSONValue.object([:]))
    }

    func testRequestPreservesParams() throws {
        let params = JSONValue.object([
            "pane_id": .string("w1:p1"),
            "keys": .array([.string("enter")]),
        ])
        let data = SocketRPC.encodeRequest(id: "1", method: "pane.send_input", params: params)
        let value = try JSONDecoder().decode(JSONValue.self, from: data.dropLast())
        XCTAssertEqual(value["params"], params)
    }

    // MARK: - Responses

    func testDecodeResponseReturnsResult() throws {
        let line = Data(#"{"id":"1","result":{"protocol":19}}"#.utf8)
        let result = try SocketRPC.decodeResponse(line)
        XCTAssertEqual(result["protocol"], JSONValue.number(19))
    }

    func testDecodeResponseSurfacesRPCError() {
        let line = Data(#"{"id":"1","error":{"code":"agent_name_taken","message":"taken"}}"#.utf8)
        XCTAssertThrowsError(try SocketRPC.decodeResponse(line)) { error in
            guard case HerdrError.rpc(let code, let message) = error else {
                return XCTFail("expected .rpc, got \(error)")
            }
            XCTAssertEqual(code, "agent_name_taken")
            XCTAssertEqual(message, "taken")
        }
    }

    func testDecodeResponseRejectsEmptyAndMalformed() {
        let malformed: [Data?] = [nil, Data(), Data("not json".utf8), Data(#"{"id":"1"}"#.utf8)]
        for line in malformed {
            XCTAssertThrowsError(try SocketRPC.decodeResponse(line)) { error in
                guard case HerdrError.malformedResponse = error else {
                    return XCTFail("expected .malformedResponse, got \(error)")
                }
            }
        }
    }

    // MARK: - Models

    private static let agentJSON = """
    {
      "terminal_id": "t1",
      "agent": "claude",
      "terminal_title": "\\u001b[1mfix the parser\\u001b[0m",
      "terminal_title_stripped": "fix the parser",
      "agent_status": "blocked",
      "workspace_id": "w1",
      "tab_id": "w1:t1",
      "pane_id": "w1:p1",
      "focused": true,
      "cwd": "/Users/vincent/Projects/herdrm",
      "revision": 42
    }
    """

    func testAgentInfoDecodesSnakeCaseKeys() throws {
        let agent = try JSONDecoder().decode(AgentInfo.self, from: Data(Self.agentJSON.utf8))
        XCTAssertEqual(agent.paneID, "w1:p1")
        XCTAssertEqual(agent.workspaceID, "w1")
        XCTAssertEqual(agent.tabID, "w1:t1")
        XCTAssertEqual(agent.terminalID, "t1")
        XCTAssertEqual(agent.status, .blocked)
        XCTAssertEqual(agent.agent, "claude")
        XCTAssertEqual(agent.title, "fix the parser", "the stripped title wins over the ANSI one")
        XCTAssertEqual(agent.revision, 42)
        XCTAssertEqual(agent.id, agent.paneID)
    }

    /// herdr omits `agent` and `agent_status` while it is still sniffing a fresh pane.
    func testAgentInfoToleratesMissingOptionalFields() throws {
        let json = #"{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2"}"#
        let agent = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(agent.status, .unknown)
        XCTAssertEqual(agent.agent, "agent")
        XCTAssertEqual(agent.title, "agent", "with no title at all the kind is the fallback")
        XCTAssertNil(agent.revision)
    }

    func testWorkspaceInfoDecodes() throws {
        let json = """
        {"workspace_id":"w1","number":1,"label":"herdrm","focused":true,
         "pane_count":3,"tab_count":2,"active_tab_id":"w1:t1","agent_status":"working"}
        """
        let workspace = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(workspace.workspaceID, "w1")
        XCTAssertEqual(workspace.label, "herdrm")
        XCTAssertEqual(workspace.paneCount, 3)
        XCTAssertEqual(workspace.tabCount, 2)
        XCTAssertEqual(workspace.activeTabID, "w1:t1")
        XCTAssertEqual(workspace.status, .working)
    }

    func testPaneInfoDistinguishesAgentPanesFromShells() throws {
        let shell = #"{"pane_id":"w1:p9","workspace_id":"w1","terminal_title":"zsh"}"#
        let agent = #"{"pane_id":"w1:p1","workspace_id":"w1","agent":"codex","agent_status":"idle"}"#
        XCTAssertFalse(try JSONDecoder().decode(PaneInfo.self, from: Data(shell.utf8)).hasAgent)
        XCTAssertTrue(try JSONDecoder().decode(PaneInfo.self, from: Data(agent.utf8)).hasAgent)
    }

    func testSnapshotDecodesProtocolKey() throws {
        let json = """
        {"agents":[\(Self.agentJSON)],
         "workspaces":[{"workspace_id":"w1","number":1,"label":"herdrm"}],
         "panes":[{"pane_id":"w1:p1","workspace_id":"w1"}],
         "focused_pane_id":"w1:p1","focused_workspace_id":"w1",
         "version":"0.8.0","protocol":19}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.protocolVersion, 19)
        XCTAssertEqual(snapshot.focusedPaneID, "w1:p1")
        XCTAssertEqual(snapshot.focusedWorkspaceID, "w1")
        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.panes?.count, 1)
    }

    /// `panes` is absent on older servers; the app must not fail the whole snapshot.
    func testSnapshotToleratesMissingPanes() throws {
        let json = #"{"agents":[],"workspaces":[]}"#
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.panes)
    }

    func testPingDecodesProtocolKey() throws {
        let pong = try JSONDecoder().decode(PingResult.self, from: Data(#"{"version":"0.8.0","protocol":19}"#.utf8))
        XCTAssertEqual(pong.version, "0.8.0")
        XCTAssertEqual(pong.protocolVersion, 19)
    }

    // MARK: - Event kinds

    /// Pane-scoped kinds need a pane_id and are rejected by events.subscribe when asked
    /// for globally — subscribing to one would break the whole stream.
    func testGlobalEventKindsExcludePaneScopedOnes() {
        let paneScoped = ["pane.agent_status_changed", "pane.scroll_changed", "pane.output_matched"]
        for kind in paneScoped {
            XCTAssertFalse(HerdrEvent.allKinds.contains(kind), "\(kind) is not globally subscribable")
        }
        XCTAssertTrue(HerdrEvent.allKinds.contains("pane.updated"))
        XCTAssertTrue(HerdrEvent.allKinds.contains("workspace.renamed"))
        XCTAssertEqual(Set(HerdrEvent.allKinds).count, HerdrEvent.allKinds.count, "duplicate kinds")
    }

    // MARK: - Errors

    func testIncompatibleProtocolMessageTracksTheMinimum() {
        let message = HerdrError.incompatibleProtocol(3).errorDescription ?? ""
        XCTAssertTrue(message.contains("\(HerdrService.minimumProtocolVersion)"), message)
    }
}
