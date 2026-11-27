import Cocoa
import Darwin

/// Finds running `agy` CLI sessions and the GUI app whose window each one lives in,
/// so the HUD can show and dock on a terminal the same way it does on Antigravity.
@MainActor
enum AgentProcessScanner {
    struct CLIAgent: Equatable {
        let pid: pid_t
        /// Regular (Dock-visible) apps showing this session. More than one only for
        /// tmux, where any attached client's terminal may be displaying it.
        let hostPids: Set<pid_t>
        /// Value of AGY_CLI_AUTO_COMPACT_OVERRIDE from the process environment, if set.
        let autoCompactOverride: String?
        /// Canonical tmux server socket path from `$TMUX`, if running inside tmux.
        let tmuxSocket: String?
        /// Tmux pane ID from `$TMUX_PANE` (e.g. `%18`), if running inside tmux.
        let tmuxPane: String?
    }

    struct OpenConversationHandles: Equatable {
        let lockIds: Set<String>
        let dbIds: Set<String>
        let brainIds: Set<String>

        static let empty = OpenConversationHandles(lockIds: [], dbIds: [], brainIds: [])
    }

    private struct CachedOpenHandles {
        let handles: OpenConversationHandles
        let checkedAt: Date
    }

    private static var cached: [CLIAgent] = []
    private static var cachedAt: Date = .distantPast
    private static var cachedTmuxBinaryPath: String?
    private static var openHandlesCache: [pid_t: CachedOpenHandles] = [:]

    /// `agy <subcommand>` invocations that are tooling, not an agent session.
    private static let nonSessionSubcommands: Set<String> = [
        "agentapi", "agent", "agents", "changelog", "help", "install", "mcp",
        "mic-serve", "models", "plugin", "plugins", "remote-control", "update",
        "--help", "-h", "--version", "-v",
    ]

    private static let fallbackTmuxPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    static func liveCLIAgents(maxAge: TimeInterval = 1.0) -> [CLIAgent] {
        if Date().timeIntervalSince(cachedAt) < maxAge {
            return cached
        }
        cached = scan()
        cachedAt = Date()
        return cached
    }

    static func invalidateCache() {
        cachedAt = .distantPast
    }

    static func cliHostPids() -> Set<pid_t> {
        liveCLIAgents().reduce(into: Set<pid_t>()) { $0.formUnion($1.hostPids) }
    }

    static func tmuxExecutablePath() -> String? {
        if let cachedTmuxBinaryPath, FileManager.default.isExecutableFile(atPath: cachedTmuxBinaryPath) {
            return cachedTmuxBinaryPath
        }
        for path in fallbackTmuxPaths where FileManager.default.isExecutableFile(atPath: path) {
            cachedTmuxBinaryPath = path
            return path
        }
        return nil
    }

    static func hostAppPid(of pid: pid_t) -> pid_t? {
        ancestry(of: pid).host
    }

    static func isDescendant(_ pid: pid_t, of ancestorPid: pid_t) -> Bool {
        guard pid > 1, ancestorPid > 1 else { return false }
        if pid == ancestorPid { return true }
        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPid(of: current), parent > 1 else { break }
            if parent == ancestorPid { return true }
            current = parent
        }
        return false
    }

    static func canonicalPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func parseTmuxSocket(_ rawTmuxEnv: String?) -> String? {
        guard let raw = rawTmuxEnv?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        let socketPart: String
        if parts.count >= 3 {
            socketPart = parts.dropLast(2).joined(separator: ",")
        } else {
            socketPart = String(parts[0])
        }
        let canonical = canonicalPath(socketPart)
        return canonical.isEmpty ? nil : canonical
    }

    static func tmuxPaneKey(socket: String?, pane: String?) -> String? {
        guard let socket, !socket.isEmpty, let pane, !pane.isEmpty else { return nil }
        let canon = canonicalPath(socket)
        let trimmedPane = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canon.isEmpty, !trimmedPane.isEmpty else { return nil }
        return "\(canon)|\(trimmedPane)"
    }

    static func invalidateOpenHandlesCache(for pid: pid_t? = nil) {
        if let pid {
            openHandlesCache.removeValue(forKey: pid)
        } else {
            openHandlesCache.removeAll()
        }
    }

    /// Inspects open vnode file descriptors of a single `agy` process via libproc
    /// to discover which CLI conversation(s) it currently has locked/open.
    static func openConversationHandles(for pid: pid_t, maxAge: TimeInterval = 0.5) -> OpenConversationHandles {
        let now = Date()
        if let entry = openHandlesCache[pid], now.timeIntervalSince(entry.checkedAt) < maxAge {
            return entry.handles
        }
        let handles = scanOpenConversationHandles(of: pid)
        openHandlesCache[pid] = CachedOpenHandles(handles: handles, checkedAt: now)
        if openHandlesCache.count > 32 {
            let cutoff = now.addingTimeInterval(-30)
            openHandlesCache = openHandlesCache.filter { $0.value.checkedAt >= cutoff && isAlive($0.key) }
        }
        return handles
    }

    static func autoCompactOverride(for pid: pid_t) -> (found: Bool, value: String?) {
        if let agent = liveCLIAgents().first(where: { $0.pid == pid }) {
            return (true, agent.autoCompactOverride)
        }
        guard isAlive(pid), let (_, env) = argumentsAndEnvironment(of: pid) else {
            return (false, nil)
        }
        let raw = env["AGY_CLI_AUTO_COMPACT_OVERRIDE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, (raw?.isEmpty == false) ? raw : nil)
    }

    /// Fallback when a CLI conversation hasn't linked an agy pid via hooks yet
    /// (e.g. AgyHUD restarted mid-session). Prefers sessions hosted by the frontmost app.
    static func fallbackAutoCompactOverride() -> String? {
        let agents = liveCLIAgents()
        guard !agents.isEmpty else { return nil }
        if let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let matching = agents.filter { $0.hostPids.contains(frontPid) }
            if !matching.isEmpty {
                let unique = Set(matching.map { $0.autoCompactOverride ?? "" })
                if unique.count == 1, let only = unique.first, !only.isEmpty {
                    return only
                }
            }
        }
        let uniqueAll = Set(agents.map { $0.autoCompactOverride ?? "" })
        if uniqueAll.count == 1, let only = uniqueAll.first, !only.isEmpty {
            return only
        }
        return nil
    }

    /// Hooks report their parent pid, which is `agy` itself or a shell it spawned.
    /// Returns the enclosing `agy` pid, or nil if that chain is already gone.
    static func enclosingAgentPid(of pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<6 {
            guard current > 1 else { return nil }
            if processName(current) == "agy" {
                return current
            }
            guard let parent = parentPid(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Scan

    private static func scan() -> [CLIAgent] {
        var agentPids: [pid_t] = []
        var tmuxPids: [pid_t] = []
        for pid in allPids() where pid > 1 {
            switch processName(pid) {
            case "agy": agentPids.append(pid)
            case "tmux": tmuxPids.append(pid)
            default: break
            }
        }
        guard !agentPids.isEmpty else { return [] }

        if cachedTmuxBinaryPath == nil {
            for tmuxPid in tmuxPids {
                if let path = executablePath(of: tmuxPid), !path.isEmpty {
                    cachedTmuxBinaryPath = path
                    break
                }
            }
        }

        // A tmux client sits under a terminal app; the server is daemonized and has
        // no GUI ancestor. Client hosts are resolved only if a session needs them.
        var tmuxClientHosts: Set<pid_t>?
        func resolveTmuxClientHosts() -> Set<pid_t> {
            if let known = tmuxClientHosts { return known }
            let hosts = Set(tmuxPids.compactMap { ancestry(of: $0).host })
            tmuxClientHosts = hosts
            return hosts
        }

        var agents: [CLIAgent] = []
        for pid in agentPids {
            guard let (args, env) = argumentsAndEnvironment(of: pid) else { continue }
            if args.count > 1, nonSessionSubcommands.contains(args[1]) {
                continue
            }

            let lineage = ancestry(of: pid)
            var hosts: Set<pid_t> = []
            let tmuxSocket = parseTmuxSocket(env["TMUX"])
            let rawPane = env["TMUX_PANE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tmuxPane = (rawPane?.isEmpty == false) ? rawPane : nil
            if let host = lineage.host {
                hosts.insert(host)
            } else if lineage.passedTmux || tmuxSocket != nil {
                hosts = resolveTmuxClientHosts()
            }
            // Session-manager daemons break the process chain too; the terminal still
            // stamps its bundle id on everything it launched.
            if hosts.isEmpty, let bundleId = env["__CFBundleIdentifier"],
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                   .first(where: { $0.activationPolicy == .regular }) {
                hosts.insert(app.processIdentifier)
            }
            let overrideRaw = env["AGY_CLI_AUTO_COMPACT_OVERRIDE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoCompactOverride = (overrideRaw?.isEmpty == false) ? overrideRaw : nil
            agents.append(CLIAgent(
                pid: pid,
                hostPids: hosts,
                autoCompactOverride: autoCompactOverride,
                tmuxSocket: tmuxSocket,
                tmuxPane: tmuxPane
            ))
        }
        return agents
    }

    /// Walks up the parent chain to the first regular GUI app.
    private static func ancestry(of pid: pid_t) -> (host: pid_t?, passedTmux: Bool) {
        var passedTmux = false
        var current = pid
        for _ in 0..<32 {
            guard let parent = parentPid(of: current), parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular {
                return (parent, passedTmux)
            }
            if processName(parent) == "tmux" {
                passedTmux = true
            }
            current = parent
        }
        return (nil, passedTmux)
    }

    // MARK: - libproc / sysctl helpers

    private static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func scanOpenConversationHandles(of pid: pid_t) -> OpenConversationHandles {
        guard pid > 1 else { return .empty }
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return .empty }

        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimated = Int(bufSize) / stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: estimated + 32)
        let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard actual > 0 else { return .empty }

        let actualCount = Int(actual) / stride
        let cliRoot = AgentSource.cli.rootDir.path
        let presencePrefix = "\(cliRoot)/presence/"
        let conversationsPrefix = "\(cliRoot)/conversations/"
        let brainPrefix = "\(cliRoot)/brain/"

        var lockIds: Set<String> = []
        var dbIds: Set<String> = []
        var brainIds: Set<String> = []

        for i in 0..<actualCount {
            guard fds[i].proc_fdtype == PROX_FDTYPE_VNODE else { continue }
            var vpi = vnode_fdinfowithpath()
            let vpiSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            let got = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vpi, vpiSize)
            guard got > 0 else { continue }

            let path = withUnsafePointer(to: vpi.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !path.isEmpty else { continue }

            if path.hasPrefix(presencePrefix), path.hasSuffix(".lock") {
                let id = String(path.dropFirst(presencePrefix.count).dropLast(5))
                if !id.isEmpty && !id.contains("/") {
                    lockIds.insert(id)
                }
            } else if path.hasPrefix(conversationsPrefix) {
                let rest = String(path.dropFirst(conversationsPrefix.count))
                if !rest.contains("/") {
                    for suffix in [".db", ".db-wal", ".db-shm"] {
                        if rest.hasSuffix(suffix) {
                            let id = String(rest.dropLast(suffix.count))
                            if !id.isEmpty {
                                dbIds.insert(id)
                            }
                            break
                        }
                    }
                }
            } else if path.hasPrefix(brainPrefix) {
                let rest = String(path.dropFirst(brainPrefix.count))
                if !rest.isEmpty, let first = rest.split(separator: "/").first {
                    let id = String(first)
                    if !id.isEmpty && !id.hasPrefix(".") {
                        brainIds.insert(id)
                    }
                }
            }
        }

        return OpenConversationHandles(lockIds: lockIds, dbIds: dbIds, brainIds: brainIds)
    }

    /// KERN_PROCARGS2 layout: argc, exec path, NUL padding, argv strings, env strings.
    private static func argumentsAndEnvironment(of pid: pid_t) -> (args: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        var env: [String: String] = [:]
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let text = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1

            if args.count < argc {
                args.append(text)
            } else if text.isEmpty {
                break
            } else if let eq = text.firstIndex(of: "=") {
                env[String(text[..<eq])] = String(text[text.index(after: eq)...])
            }
        }
        return (args, env)
    }
}
