import XCTest
@testable import HerdrKit

/// Sidebar ordering, ⌘K matching, notification transitions and reconnect backoff.
/// Pure logic — runs without a herdr server.
final class ConsoleLogicTests: XCTestCase {

    /// Builds an `AgentInfo` the way herdr does: through the wire format, so the fixtures
    /// stay honest about which JSON keys the model actually reads.
    private func agent(
        _ paneID: String,
        _ status: AgentStatus = .idle,
        revision: Int? = nil,
        kind: String = "claude",
        title: String? = nil,
        workspace: String = "w1"
    ) -> AgentInfo {
        var fields: [String: Any] = [
            "workspace_id": workspace,
            "tab_id": "\(workspace):t1",
            "pane_id": paneID,
            "agent": kind,
            "agent_status": status.rawValue,
        ]
        if let title { fields["terminal_title_stripped"] = title }
        if let revision { fields["revision"] = revision }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(AgentInfo.self, from: data)
    }

    // MARK: - Ordering

    func testStatusBucketsOrderBlockedFirstAndUnknownLast() {
        let sorted = ConsoleLogic.sorted([
            agent("p-idle", .idle),
            agent("p-working", .working),
            agent("p-done", .done),
            agent("p-blocked", .blocked),
            agent("p-unknown", .unknown),
        ])
        XCTAssertEqual(sorted.map(\.paneID), ["p-blocked", "p-done", "p-working", "p-idle", "p-unknown"])
    }

    func testWithinABucketTheMostRecentRevisionComesFirst() {
        let sorted = ConsoleLogic.sorted([
            agent("p1", .working, revision: 3),
            agent("p2", .working, revision: 9),
            agent("p3", .working, revision: 5),
        ])
        XCTAssertEqual(sorted.map(\.paneID), ["p2", "p3", "p1"])
    }

    /// Every snapshot re-sorts the sidebar; equal keys must not reshuffle the rows.
    func testOrderIsDeterministicWhenStatusAndRevisionTie() {
        let agents = [agent("w1:p3"), agent("w1:p1"), agent("w1:p2")]
        XCTAssertEqual(ConsoleLogic.sorted(agents).map(\.paneID), ["w1:p1", "w1:p2", "w1:p3"])
        XCTAssertEqual(
            ConsoleLogic.sorted(agents).map(\.paneID),
            ConsoleLogic.sorted(agents.reversed()).map(\.paneID)
        )
    }

    func testMissingRevisionSortsAsZero() {
        let sorted = ConsoleLogic.sorted([agent("p1"), agent("p2", revision: 1)])
        XCTAssertEqual(sorted.map(\.paneID), ["p2", "p1"])
    }

    // MARK: - Search

    func testEmptyQueryMatchesEverythingSoThePaletteOpensAsAList() {
        XCTAssertTrue(ConsoleLogic.matches(query: "", fields: ["anything"]))
        XCTAssertTrue(ConsoleLogic.matches(query: "   ", fields: [nil]))
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(ConsoleLogic.matches(query: "CLAUDE", fields: ["claude"]))
        XCTAssertTrue(ConsoleLogic.matches(query: "resume", fields: ["résumé parser"]))
        XCTAssertFalse(ConsoleLogic.matches(query: "codex", fields: ["claude", nil]))
    }

    func testAnyFieldCanMatch() {
        let fields: [String?] = ["fix the parser", "claude", "mac-studio", "herdrm"]
        XCTAssertTrue(ConsoleLogic.matches(query: "studio", fields: fields))
        XCTAssertTrue(ConsoleLogic.matches(query: "herdrm", fields: fields))
        XCTAssertFalse(ConsoleLogic.matches(query: "gemini", fields: fields))
    }

    // MARK: - Notification transitions

    func testFirstSnapshotNeverNotifies() {
        let agents = [agent("p1", .blocked), agent("p2", .done)]
        XCTAssertTrue(ConsoleLogic.notifiable(previous: [:], agents: agents).isEmpty)
    }

    func testOnlyTransitionsIntoBlockedOrDoneNotify() {
        let previous: [String: AgentStatus] = [
            "p1": .working,   // → blocked   notifies
            "p2": .working,   // → done      notifies
            "p3": .blocked,   // → blocked   unchanged, silent
            "p4": .blocked,   // → working   silent
            "p5": .working,   // → idle      silent
        ]
        let notified = ConsoleLogic.notifiable(previous: previous, agents: [
            agent("p1", .blocked),
            agent("p2", .done),
            agent("p3", .blocked),
            agent("p4", .working),
            agent("p5", .idle),
        ])
        XCTAssertEqual(Set(notified.map(\.paneID)), ["p1", "p2"])
    }

    /// A pane herdr has not reported before (a brand-new agent) has no previous status,
    /// so it stays silent until it actually transitions.
    func testUnseenPaneDoesNotNotify() {
        let notified = ConsoleLogic.notifiable(previous: ["p1": .idle], agents: [agent("p9", .blocked)])
        XCTAssertTrue(notified.isEmpty)
    }

    func testStatusMapRoundTrips() {
        let map = ConsoleLogic.statusMap([agent("p1", .blocked), agent("p2", .idle)])
        XCTAssertEqual(map, ["p1": .blocked, "p2": .idle])
    }

    // MARK: - Backoff

    func testBackoffDoublesAndCaps() {
        var delay: Double = 1
        var schedule: [Double] = [delay]
        for _ in 0..<7 {
            delay = ConsoleLogic.nextBackoff(after: delay)
            schedule.append(delay)
        }
        XCTAssertEqual(schedule, [1, 2, 4, 8, 16, 30, 30, 30])
    }
}

/// The SSH plumbing that can be checked without an actual host.
final class SSHTunnelPathTests: XCTestCase {

    /// Swift's `hashValue` is seeded per process; the socket name must not be.
    func testTokenIsStableAcrossCallsAndDistinctPerTarget() {
        XCTAssertEqual(SSHTunnel.token(for: "vincent@10.10.10.87"), SSHTunnel.token(for: "vincent@10.10.10.87"))
        XCTAssertNotEqual(SSHTunnel.token(for: "vincent@10.10.10.87"), SSHTunnel.token(for: "vincent@10.10.10.88"))
        XCTAssertNotEqual(SSHTunnel.token(for: "a@host"), SSHTunnel.token(for: "b@host"))
    }

    /// sockaddr_un caps Unix socket paths at 104 bytes — the forwarded socket and the ssh
    /// control socket both have to fit, however long the target is.
    func testTunnelPathsFitInSockaddrUn() throws {
        let target = "some-long-user-name@some-long-host-name.example.internal"

        let socketPath = SSHTunnel.supportDirectory()
            .appendingPathComponent("\(SSHTunnel.token(for: target)).sock").path
        XCTAssertLessThan(socketPath.utf8.count, 104, socketPath)

        let options = SSHTunnel.controlOptions(for: target)
        guard let controlPath = options.first(where: { $0.hasPrefix("ControlPath=") }) else {
            return XCTFail("no ControlPath in \(options)")
        }
        XCTAssertLessThan(controlPath.utf8.count - "ControlPath=".utf8.count, 104, controlPath)
    }

    func testControlOptionsEnableMultiplexing() {
        let options = SSHTunnel.controlOptions(for: "vincent@host")
        XCTAssertTrue(options.contains("ControlMaster=auto"))
        XCTAssertTrue(options.contains { $0.hasPrefix("ControlPersist=") })
        XCTAssertEqual(options.filter { $0 == "-o" }.count, 3, "each option needs its own -o")
    }
}

/// Pane output is read in `ansi` format; anything shown outside a terminal goes
/// through the stripper first.
final class TerminalTextTests: XCTestCase {

    func testStripsSGRSequences() {
        XCTAssertEqual(TerminalText.stripANSI("\u{1B}[1;31mred\u{1B}[0m"), "red")
        XCTAssertEqual(TerminalText.stripANSI("plain"), "plain")
    }

    func testStripsCursorMovesAndEraseSequences() {
        XCTAssertEqual(TerminalText.stripANSI("a\u{1B}[2Kb\u{1B}[10;20Hc"), "abc")
        XCTAssertEqual(TerminalText.stripANSI("\u{1B}[?25lhidden\u{1B}[?25h"), "hidden")
    }

    func testStripsOSCTitleSequences() {
        XCTAssertEqual(TerminalText.stripANSI("\u{1B}]0;window title\u{07}body"), "body")
        XCTAssertEqual(TerminalText.stripANSI("\u{1B}]8;;https://example.com\u{1B}\\link"), "link")
    }

    func testDropsCarriageReturnsButKeepsNewlines() {
        XCTAssertEqual(TerminalText.stripANSI("one\r\ntwo"), "one\ntwo")
    }

    func testTailTakesTheLastNonBlankLines() {
        let output = """
        building…

        \u{1B}[32m✓\u{1B}[0m done

        Do you want to apply this patch? (y/n)
        """
        XCTAssertEqual(TerminalText.tail(output, lines: 1), "Do you want to apply this patch? (y/n)")
        XCTAssertEqual(TerminalText.tail(output, lines: 2), "✓ done Do you want to apply this patch? (y/n)")
    }

    func testTailTruncatesLongOutput() {
        let long = String(repeating: "x", count: 400)
        let tail = TerminalText.tail(long, limit: 40)
        XCTAssertEqual(tail?.count, 40)
        XCTAssertTrue(tail?.hasSuffix("…") ?? false)
    }

    func testTailIsNilForBlankOutput() {
        XCTAssertNil(TerminalText.tail("\n  \n\u{1B}[0m\n"))
        XCTAssertNil(TerminalText.tail(""))
    }
}
