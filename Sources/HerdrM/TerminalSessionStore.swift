import AppKit
import Foundation
import HerdrKit
import SwiftTerm

/// One live `herdr agent attach` process and the terminal view it draws into.
///
/// The view outlives any single selection: switching agents hands the same view to a
/// different container instead of tearing the process down and starting a new one.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let ref: PaneRef
    let device: Device
    let view: LocalProcessTerminalView

    /// False once the attach process exits — a dropped SSH connection, a closed pane,
    /// or herdr itself going away. The detail view turns this into a reconnect prompt
    /// rather than leaving a frozen terminal on screen.
    private(set) var isRunning = false
    private(set) var lastExitCode: Int32?

    private let onChange: () -> Void

    init(ref: PaneRef, device: Device, onChange: @escaping () -> Void) {
        self.ref = ref
        self.device = device
        self.onChange = onChange
        // A real starting size: startProcess derives the initial winsize from the frame,
        // and a zero-sized terminal makes the remote app draw for a 0x0 screen.
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        super.init()
        view.processDelegate = self
        start()
    }

    func start() {
        guard !isRunning else { return }
        let command = HerdrService(device: device).attachCommand(paneID: ref.paneID)
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=en_US.UTF-8")
        lastExitCode = nil
        isRunning = true
        view.startProcess(executable: command.executable, args: command.args, environment: environment)
    }

    func terminate() {
        guard isRunning else { return }
        isRunning = false
        view.terminate()
    }

    func apply(fontName: String, fontSize: Double, dark: Bool, mouseReporting: Bool) {
        let font = TerminalDefaults.font(name: fontName, size: fontSize)
        if view.font != font {
            view.font = font
        }
        view.allowMouseReporting = mouseReporting
        let background: NSColor = dark
            ? NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
            : .white
        let foreground: NSColor = dark
            ? NSColor(srgbRed: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
            : NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3A / 255, alpha: 1)
        if view.nativeBackgroundColor != background {
            view.nativeBackgroundColor = background
            view.nativeForegroundColor = foreground
            view.needsDisplay = true
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        lastExitCode = exitCode
        onChange()
    }
}

/// Keeps recently viewed terminals attached so switching between agents is instant.
///
/// The cache is deliberately small and short-lived. herdr treats an attached pane as one
/// you are watching and holds back its "done" notification, so a pane the user has walked
/// away from must not stay attached: anything unselected for `idleTimeout` is detached,
/// and at most `maxIdleSessions` background terminals are kept regardless.
@MainActor
final class TerminalSessionStore: ObservableObject {
    static let shared = TerminalSessionStore()

    static let idleTimeout: TimeInterval = 45
    static let maxIdleSessions = 2
    private static let sweepInterval: TimeInterval = 15

    /// Bumped whenever a session dies or is dropped, so views re-read `isDisconnected`.
    @Published private(set) var generation = 0

    private var sessions: [PaneRef: TerminalSession] = [:]
    private var lastUsed: [PaneRef: Date] = [:]
    private var selected: PaneRef?
    private var sweeper: Task<Void, Never>?

    /// The live session for a pane, started on first use.
    /// Called from `updateNSView`, so it deliberately publishes nothing.
    func session(for ref: PaneRef, device: Device) -> TerminalSession {
        selected = ref
        lastUsed[ref] = Date()
        if let existing = sessions[ref] { return existing }
        let session = TerminalSession(ref: ref, device: device) { [weak self] in
            self?.bump()
        }
        sessions[ref] = session
        startSweeper()
        return session
    }

    func isDisconnected(_ ref: PaneRef) -> Bool {
        guard let session = sessions[ref] else { return false }
        return !session.isRunning
    }

    /// Restarts the attach process for a pane whose terminal died.
    func reconnect(_ ref: PaneRef, device: Device) {
        if let session = sessions[ref] {
            session.start()
        } else {
            _ = self.session(for: ref, device: device)
        }
        bump()
    }

    /// Drops terminals for panes herdr no longer reports (closed agents, removed devices).
    func prune(keeping live: Set<PaneRef>) {
        let stale = sessions.keys.filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        for ref in stale { drop(ref) }
        bump()
    }

    func close(_ ref: PaneRef) {
        guard sessions[ref] != nil else { return }
        drop(ref)
        bump()
    }

    /// Detaches everything — used when the app is going away.
    func closeAll() {
        for ref in sessions.keys { drop(ref) }
        sweeper?.cancel()
        sweeper = nil
        bump()
    }

    // MARK: - Private

    private func drop(_ ref: PaneRef) {
        sessions[ref]?.terminate()
        sessions[ref]?.view.removeFromSuperview()
        sessions.removeValue(forKey: ref)
        lastUsed.removeValue(forKey: ref)
        if selected == ref { selected = nil }
    }

    private func bump() {
        generation &+= 1
    }

    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.sweepInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.trimIdle()
            }
        }
    }

    /// Detaches background terminals that are too old or too many. The selected pane is
    /// never dropped.
    private func trimIdle() {
        let now = Date()
        var idle = sessions.keys
            .filter { $0 != selected }
            .sorted { (lastUsed[$0] ?? .distantPast) > (lastUsed[$1] ?? .distantPast) }

        var dropped = false
        while idle.count > Self.maxIdleSessions, let ref = idle.popLast() {
            drop(ref)
            dropped = true
        }
        for ref in idle where now.timeIntervalSince(lastUsed[ref] ?? .distantPast) > Self.idleTimeout {
            drop(ref)
            dropped = true
        }
        if dropped { bump() }
    }
}
