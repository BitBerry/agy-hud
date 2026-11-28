import Foundation

struct TmuxClientInfo: Equatable, Sendable {
    let activity: Int64
    let clientPid: pid_t
    let sessionId: String
    let windowId: String
    let paneId: String
    let panePid: pid_t
    let isFocused: Bool
}

struct TmuxPaneInfo: Equatable, Sendable {
    let sessionId: String
    let windowId: String
    let paneId: String
    let isActive: Bool
    let panePid: pid_t
}

struct TmuxServerSnapshot: Equatable, Sendable {
    let socket: String
    let clients: [TmuxClientInfo]
    let panes: [TmuxPaneInfo]
    let focusEventsEnabled: Bool
}

/// Polls active tmux servers (only those hosting live `agy` CLI processes) on a
/// background queue so switching tmux panes, windows, or sessions updates the HUD
/// rapidly without blocking the main thread or requiring user tmux.conf edits.
@MainActor
final class TmuxFocusMonitor {
    private let queue = DispatchQueue(label: "com.local.agy-hud.tmux", qos: .userInitiated)
    private var timer: Timer?
    private var isActive = false
    private var isPolling = false
    private var pendingProbe = false
    private var pendingForcedProbe = false

    private(set) var snapshots: [String: TmuxServerSnapshot] = [:]
    private(set) var lastPollStartedAt: Date = .distantPast
    var onSnapshotChanged: (() -> Void)?
    var onPollCompleted: (() -> Void)?

    func setActive(_ active: Bool) {
        if active == isActive {
            if active && timer == nil {
                startTimer()
            }
            return
        }
        isActive = active
        if active {
            startTimer()
            probeNow()
        } else {
            stopTimer()
        }
    }

    func stop() {
        isActive = false
        stopTimer()
    }

    func probeNow(force: Bool = false) {
        guard isActive || force else { return }
        if isPolling {
            pendingProbe = true
            if force {
                pendingForcedProbe = true
            }
            return
        }

        let agents = AgentProcessScanner.liveCLIAgents()
        let sockets = Array(Set(agents.compactMap(\.tmuxSocket))).sorted()
        guard !sockets.isEmpty, let tmuxPath = AgentProcessScanner.tmuxExecutablePath() else {
            if !snapshots.isEmpty {
                snapshots.removeAll()
                onSnapshotChanged?()
            }
            return
        }

        isPolling = true
        pendingProbe = false
        pendingForcedProbe = false
        let pollStartedAt = Date()

        queue.async { [weak self] in
            var next: [String: TmuxServerSnapshot] = [:]
            for socket in sockets {
                if let snap = Self.queryServer(tmuxPath: tmuxPath, socket: socket) {
                    next[socket] = snap
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                self.lastPollStartedAt = pollStartedAt
                let changed = (next != self.snapshots)
                if changed {
                    self.snapshots = next
                    self.onSnapshotChanged?()
                } else {
                    self.onPollCompleted?()
                }
                if self.pendingProbe && (self.isActive || self.pendingForcedProbe) {
                    let nextForce = self.pendingForcedProbe
                    self.pendingProbe = false
                    self.pendingForcedProbe = false
                    self.probeNow(force: nextForce)
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeNow()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Subprocess Query (background queue)

    private nonisolated static func queryServer(tmuxPath: String, socket: String) -> TmuxServerSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = [
            "-u",
            "-S", socket,
            "list-clients", "-F", "C|#{client_activity}|#{client_pid}|#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}|#{client_flags}",
            ";",
            "list-panes", "-a", "-F", "P|#{session_id}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_pid}",
            ";",
            "display-message", "-p", "O|#{focus-events}",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let outPipe = Pipe()
        process.standardOutput = outPipe

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            return nil
        }

        // Close parent's copy of the write end so EOF arrives as soon as tmux exits.
        try? outPipe.fileHandleForWriting.close()

        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: timeoutWork)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        try? outPipe.fileHandleForReading.close()
        process.waitUntilExit()
        timeoutWork.cancel()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        var clients: [TmuxClientInfo] = []
        var panes: [TmuxPaneInfo] = []
        var focusEventsEnabled = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = rawLine.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let kind = cols.first else { continue }
            if kind == "C", cols.count >= 8 {
                let activity = Int64(cols[1]) ?? 0
                let clientPid = pid_t(Int32(cols[2]) ?? 0)
                let sessionId = cols[3]
                let windowId = cols[4]
                let paneId = cols[5]
                let panePid = pid_t(Int32(cols[6]) ?? 0)
                let flags = cols[7].split(separator: ",").map(String.init)
                let isFocused = flags.contains("focused")
                if clientPid > 0, !paneId.isEmpty {
                    clients.append(TmuxClientInfo(
                        activity: activity,
                        clientPid: clientPid,
                        sessionId: sessionId,
                        windowId: windowId,
                        paneId: paneId,
                        panePid: panePid,
                        isFocused: isFocused
                    ))
                }
            } else if kind == "P", cols.count >= 6 {
                let sessionId = cols[1]
                let windowId = cols[2]
                let paneId = cols[3]
                let isActive = cols[4] == "1"
                let panePid = pid_t(Int32(cols[5]) ?? 0)
                if !paneId.isEmpty {
                    panes.append(TmuxPaneInfo(
                        sessionId: sessionId,
                        windowId: windowId,
                        paneId: paneId,
                        isActive: isActive,
                        panePid: panePid
                    ))
                }
            } else if kind == "O", cols.count >= 2 {
                let val = cols[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                focusEventsEnabled = (val == "1" || val == "on")
            }
        }

        return TmuxServerSnapshot(
            socket: socket,
            clients: clients,
            panes: panes,
            focusEventsEnabled: focusEventsEnabled
        )
    }
}
