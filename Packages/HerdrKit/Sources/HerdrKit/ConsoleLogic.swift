import Foundation

/// Console ordering, matching and transition rules.
///
/// These are the decisions the sidebar, the ⌘K palette and the notifier make on every
/// snapshot. They live here — pure, `Sendable`, free of `@MainActor` and of any live
/// herdr server — so they can be unit-tested without a socket.
public enum ConsoleLogic {

    // MARK: - Ordering

    /// Everything the console sorts an agent row by, lifted out of `AgentInfo` so callers
    /// that carry extra context (a device, say) can still reuse the comparator.
    public struct OrderKey: Equatable, Sendable {
        public let status: AgentStatus
        public let revision: Int
        public let paneID: String

        public init(status: AgentStatus, revision: Int, paneID: String) {
            self.status = status
            self.revision = revision
            self.paneID = paneID
        }
    }

    /// Blocked > Done > Working > Idle > Unknown, then most recently active first.
    /// Ties break on pane id so a snapshot that repeats never reshuffles the sidebar.
    public static func sortsBefore(_ lhs: OrderKey, _ rhs: OrderKey) -> Bool {
        if lhs.status.sortBucket != rhs.status.sortBucket {
            return lhs.status.sortBucket < rhs.status.sortBucket
        }
        if lhs.revision != rhs.revision {
            return lhs.revision > rhs.revision
        }
        return lhs.paneID < rhs.paneID
    }

    public static func sorted(_ agents: [AgentInfo]) -> [AgentInfo] {
        agents.sorted { sortsBefore($0.orderKey, $1.orderKey) }
    }

    // MARK: - Search

    /// Case- and diacritic-insensitive substring match across a row's searchable fields.
    /// An empty (or whitespace-only) query matches everything, which is what makes ⌘K
    /// open as a full list rather than an empty one.
    public static func matches(query: String, fields: [String?]) -> Bool {
        let needle = normalize(query)
        guard !needle.isEmpty else { return true }
        return fields.contains { field in
            guard let field else { return false }
            return normalize(field).contains(needle)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Notifications

    /// Agents that just became blocked or done, and so deserve a notification.
    ///
    /// An empty `previous` means this is the first snapshot for the device: everything
    /// would look like a transition, so nothing notifies. Reconnecting to a herd of
    /// long-finished agents must stay silent.
    public static func notifiable(
        previous: [String: AgentStatus],
        agents: [AgentInfo]
    ) -> [AgentInfo] {
        guard !previous.isEmpty else { return [] }
        return agents.filter { agent in
            guard let old = previous[agent.paneID], old != agent.status else { return false }
            return agent.status == .blocked || agent.status == .done
        }
    }

    public static func statusMap(_ agents: [AgentInfo]) -> [String: AgentStatus] {
        Dictionary(agents.map { ($0.paneID, $0.status) }, uniquingKeysWith: { _, latest in latest })
    }

    // MARK: - Reconnect

    /// Exponential reconnect backoff, capped. Kept here so the schedule is asserted in
    /// tests instead of being buried in the session loop.
    public static func nextBackoff(after current: Double, cap: Double = 30) -> Double {
        min(current * 2, cap)
    }
}

extension AgentInfo {
    public var orderKey: ConsoleLogic.OrderKey {
        ConsoleLogic.OrderKey(status: status, revision: revision ?? 0, paneID: paneID)
    }
}

/// Turning raw terminal output into something a notification or a tooltip can show.
public enum TerminalText {

    /// Strips ANSI CSI/OSC escape sequences and carriage returns from pane output.
    /// `pane.read` is asked for `ansi` format, so anything shown outside a terminal has
    /// to come through here first.
    public static func stripANSI(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var iterator = Array(text.unicodeScalars)[...]

        while let scalar = iterator.first {
            iterator = iterator.dropFirst()
            guard scalar == "\u{1B}" else {
                if scalar != "\r" { output.unicodeScalars.append(scalar) }
                continue
            }
            guard let kind = iterator.first else { break }
            iterator = iterator.dropFirst()
            switch kind {
            case "[":
                // CSI: parameter and intermediate bytes, then a final byte in @–~.
                while let next = iterator.first {
                    iterator = iterator.dropFirst()
                    if next.value >= 0x40 && next.value <= 0x7E { break }
                }
            case "]":
                // OSC: runs until BEL or the ST sequence (ESC \).
                while let next = iterator.first {
                    iterator = iterator.dropFirst()
                    if next == "\u{07}" { break }
                    if next == "\u{1B}" {
                        iterator = iterator.dropFirst()   // the trailing backslash
                        break
                    }
                }
            default:
                break   // two-character escape: already consumed
            }
        }
        return output
    }

    /// The last few non-blank lines of pane output, flattened into one line.
    /// Used to show what an agent is actually asking instead of a generic "needs input".
    public static func tail(_ text: String, lines: Int = 2, limit: Int = 160) -> String? {
        let candidates = stripANSI(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let joined = candidates.suffix(max(lines, 1)).joined(separator: " ")
        let collapsed = joined.split(separator: " ").joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
