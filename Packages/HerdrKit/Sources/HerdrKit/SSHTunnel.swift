import Foundation

/// Forwards a remote herdr Unix socket to a local one using the system OpenSSH client
/// (`ssh -N -L local.sock:remote.sock target`), so remote devices reuse SocketRPC as-is.
/// Auth relies on the user's local SSH keys/agent (BatchMode; no password prompts).
public actor SSHTunnel {
    public let target: String
    public private(set) var localSocketPath: String?
    private var process: Process?
    private var remoteHome: String?

    /// PATH prepended on the remote side; sshd exec is not a login shell (mirrors Heeler).
    public static let remotePathExport =
        "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""

    /// Directory holding this app's forwarded sockets and control sockets.
    /// Everything under it must stay short: sockaddr_un caps paths at 104 bytes.
    static func supportDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-tunnels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stable 64-bit FNV-1a digest of an SSH target, base-36 encoded (~13 chars).
    /// Swift's `hashValue` is seeded per process, so using it here leaked a fresh socket
    /// file on every launch and could collide between two devices in the same run.
    static func token(for target: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in target.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// Connection multiplexing shared by every ssh this app spawns for a target — the
    /// socket forward, the probes, and each terminal attach. The first one pays the
    /// handshake; the rest ride it, which is what makes switching agents on a remote
    /// device feel local. `ControlPersist` keeps the master briefly after the last user.
    public static func controlOptions(for target: String) -> [String] {
        let path = supportDirectory().appendingPathComponent("cm-\(token(for: target))").path
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=120",
        ]
    }

    public init(target: String) {
        self.target = target
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Probing

    /// Resolves the remote $HOME once; also proves SSH reachability.
    public func probeRemoteHome() async throws -> String {
        if let remoteHome { return remoteHome }
        let output = try await Self.runSSH(target: target, command: "echo \"$HOME\"", timeout: 12)
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw HerdrError.tunnelFailed("could not resolve remote home (got: \(output))")
        }
        remoteHome = home
        return home
    }

    public func remoteSocketPath() async throws -> String {
        let home = try await probeRemoteHome()
        return "\(home)/.config/herdr/herdr.sock"
    }

    // MARK: - Tunnel lifecycle

    /// Ensures the forward is up and returns the local socket path.
    public func ensureUp() async throws -> String {
        if let localSocketPath, let process, process.isRunning {
            return localSocketPath
        }
        process?.terminate()
        process = nil

        let remoteSock = try await remoteSocketPath()
        let localSock = Self.supportDirectory()
            .appendingPathComponent("\(Self.token(for: target)).sock").path
        try? FileManager.default.removeItem(atPath: localSock)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "StreamLocalBindUnlink=yes",
        ] + Self.controlOptions(for: target) + [
            "-L", "\(localSock):\(remoteSock)",
            target,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc

        // Wait for the local socket to appear (ssh creates it once the session is up).
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: localSock) {
                localSocketPath = localSock
                return localSock
            }
            if !proc.isRunning {
                throw HerdrError.tunnelFailed("ssh exited with status \(proc.terminationStatus)")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        proc.terminate()
        throw HerdrError.tunnelFailed("timed out waiting for forwarded socket")
    }

    public func tearDown() {
        process?.terminate()
        process = nil
        if let localSocketPath {
            try? FileManager.default.removeItem(atPath: localSocketPath)
        }
        localSocketPath = nil
    }

    /// Sniffs the remote OS: "macos", an os-release ID like "ubuntu"/"debian", or a uname fallback.
    public static func probeOS(target: String) async throws -> String {
        let command = """
        case "$(uname -s)" in Darwin) echo macos;; Linux) . /etc/os-release 2>/dev/null; echo "${ID:-linux}";; *) uname -s | tr '[:upper:]' '[:lower:]';; esac
        """
        let output = try await runSSH(target: target, command: command, timeout: 10)
        let os = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !os.isEmpty else { throw HerdrError.tunnelFailed("empty OS probe result") }
        return os
    }

    // MARK: - One-shot exec

    /// Runs a command on the remote host and returns stdout. Used for probes.
    public static func runSSH(target: String, command: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=8",
                ] + controlOptions(for: target) + [target, command]
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.tunnelFailed("ssh spawn: \(error.localizedDescription)"))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    continuation.resume(throwing: HerdrError.tunnelFailed("ssh exited \(proc.terminationStatus)"))
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
