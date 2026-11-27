import Foundation

@MainActor
final class TranscriptMonitor {
    private struct ParsedStep {
        let stepIndex: Int
        let type: String
        let status: String
        let createdAt: Date?
        let model: String?
        let inputTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let contentLength: Int
        let hasToolCalls: Bool
        let observedDoneMs: Double?
    }

    private struct ConversationCandidate {
        let id: String
        let path: String
        let sortTime: Date
        let source: AgentSource
    }

    private struct AnnotationEntry {
        let conversationId: String
        let source: AgentSource
        let mtime: Date
        let title: String?
        let lastUserViewTime: Double?
    }

    private struct CachedTranscript {
        let path: String
        let inode: UInt64
        let readOffset: UInt64
        let lineRemainder: String
        let parsedSteps: [ParsedStep]
        var lastUsedAt: Date
    }

    private struct HookAgentLink {
        let conversationId: String
        let updatedAt: Date
        let fromSessionStart: Bool
    }

    private struct TmuxFocusKey: Equatable {
        let socket: String
        let paneId: String
        let agentPid: pid_t?
    }

    private struct IPCTmuxFocusHint {
        let socket: String
        let paneId: String
        let receivedAt: Date
    }

    private struct FocusedTmuxSelection {
        let socket: String
        let paneId: String
        let agent: AgentProcessScanner.CLIAgent?
    }

    private let state: HUDState
    private weak var quotaClient: QuotaClient?
    private let tmuxFocusMonitor = TmuxFocusMonitor()

    private var activePath: String = ""
    private var activeConversationId: String = ""
    private var activeInode: UInt64 = 0
    private var readOffset: UInt64 = 0
    private var lineRemainder: String = ""
    private var parsedSteps: [ParsedStep] = []
    private var transcriptCache: [String: CachedTranscript] = [:]

    private var vnodeSource: DispatchSourceFileSystemObject?
    private var annotationWatches: [AgentSource: DispatchSourceFileSystemObject] = [:]
    private var pollTimer: Timer?
    private var lastConversationScanAt: Date = .distantPast
    private var lastTitleFetchAt: Date = .distantPast
    private var cachedTitles: [String: String] = [:]
    private var annotationCache: [String: AnnotationEntry] = [:]
    private var lastHandledViewTime: Double = 0
    private var currentAutoViewedId: String = ""

    /// Compaction thresholds are calibrated per front end: the CLI compacts later
    /// than the desktop app for the same model.
    private var observedThresholds: [AgentSource: [String: Int]] = [:]
    private var hookTimingsByConv: [String: [HookTimingRecord]] = [:]
    private var generatingStartByConv: [String: Date] = [:]
    private var hookActiveConvBySource: [AgentSource: String] = [:]
    private var hookLastEventAtBySource: [AgentSource: Date] = [:]
    private var hookModelByConv: [String: String] = [:]
    /// Live `agy` process per CLI conversation, to notice a session killed mid-turn.
    private var agentPidByConv: [String: pid_t] = [:]
    /// Reverse index from live `agy` pid to last hook-reported conversation.
    private var convByAgentPid: [pid_t: HookAgentLink] = [:]
    /// Last known conversation per `<canonicalSocket>|<paneId>` tmux pane.
    private var convByTmuxPane: [String: String] = [:]
    /// Per-conversation AGY_CLI_AUTO_COMPACT_OVERRIDE reported by hooks or runtime-state.json.
    private var hookAutoCompactOverrideByConv: [String: String] = [:]
    private var activeHookAutoCompactOverrideBySource: [AgentSource: String] = [:]

    private var sourceByConv: [String: AgentSource] = [:]
    private var newestTranscriptBySource: [AgentSource: (id: String, path: String, mtime: Date)] = [:]
    /// Front ends shown by the most recent frontmost host window (sticky).
    private var focusSources: Set<AgentSource> = []
    /// PID of the most recent frontmost host app (terminal or Antigravity).
    private var focusHostPid: pid_t? = nil
    private var lastObservedTmuxFocus: TmuxFocusKey? = nil
    private var lastTmuxFocusChangedAt: Date = .distantPast
    private var lastUnmatchedPaneRescanKey: String = ""
    private var lastUnmatchedPaneRescanAt: Date = .distantPast
    private var ipcTmuxFocusHint: IPCTmuxFocusHint? = nil

    init(state: HUDState, quotaClient: QuotaClient) {
        self.state = state
        self.quotaClient = quotaClient
        tmuxFocusMonitor.onSnapshotChanged = { [weak self] in
            self?.handleTmuxSnapshotChanged()
        }
        loadRuntimeStateSeed()
        calibrateCompactionThresholdsAsync()
        startAnnotationsDirWatch()
        refreshNow(scanConversations: true)
    }

    func start() {
        startAnnotationsDirWatch()
        scheduleTimer()
        if state.pinnedConversationId == nil && state.sourceMode != .desktop {
            tmuxFocusMonitor.probeNow(force: true)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tmuxFocusMonitor.stop()
        stopVnodeWatch()
        stopAnnotationsDirWatch()
    }

    func updatePollingCadence() {
        scheduleTimer()
    }

    func selectConversation(_ conversationId: String?) {
        state.updatePrefs { prefs in
            prefs.pinnedConversationId = conversationId
        }
        updateTmuxPollingState()
        refreshNow(scanConversations: true)
    }

    /// Called when a window hosting Antigravity and/or the agy CLI comes to the front.
    func setFocusContext(sources: Set<AgentSource>, hostPid: pid_t?) {
        guard !sources.isEmpty else { return }
        let sourcesChanged = (sources != focusSources)
        let hostChanged = (hostPid != focusHostPid)
        focusSources = sources
        if let hostPid {
            focusHostPid = hostPid
        }
        updateTmuxPollingState()
        if sources.contains(.cli) {
            tmuxFocusMonitor.probeNow()
        }
        if sourcesChanged || hostChanged {
            refreshNow(scanConversations: false)
        }
    }

    func setFocusHostPid(_ hostPid: pid_t?) {
        guard hostPid != focusHostPid else { return }
        focusHostPid = hostPid
        updateTmuxPollingState()
        if focusSources.contains(.cli) {
            tmuxFocusMonitor.probeNow()
            refreshNow(scanConversations: false)
        }
    }

    func handleHookEvent(_ msg: HookIPCMessage) {
        if msg.event == "FocusPane" || msg.event == "TmuxFocus" {
            if let rawSocket = msg.tmuxSocket, !rawSocket.isEmpty,
               let pane = msg.tmuxPane?.trimmingCharacters(in: .whitespacesAndNewlines), !pane.isEmpty {
                let socket = AgentProcessScanner.parseTmuxSocket(rawSocket) ?? AgentProcessScanner.canonicalPath(rawSocket)
                if !socket.isEmpty {
                    ipcTmuxFocusHint = IPCTmuxFocusHint(socket: socket, paneId: pane, receivedAt: Date())
                    lastTmuxFocusChangedAt = Date()
                }
            }
            AgentProcessScanner.invalidateOpenHandlesCache()
            updateTmuxPollingState()
            tmuxFocusMonitor.probeNow(force: true)
            refreshNow(scanConversations: false)
            return
        }

        let convId = msg.conversationId ?? ""
        let source = msg.agentSource
        let eventDate = Date(timeIntervalSince1970: msg.tsMs / 1000.0)
        if source == .cli && msg.event == "SessionStart" {
            AgentProcessScanner.invalidateCache()
        }

        if !convId.isEmpty {
            hookActiveConvBySource[source] = convId
            sourceByConv[convId] = source
            if let model = msg.modelName, !model.isEmpty {
                hookModelByConv[convId] = model
            }

            var resolvedAgentPid: pid_t? = nil
            if source == .cli, let hookParent = msg.agentPid,
               let agentPid = AgentProcessScanner.enclosingAgentPid(of: hookParent) {
                resolvedAgentPid = agentPid
                agentPidByConv[convId] = agentPid
                convByAgentPid[agentPid] = HookAgentLink(
                    conversationId: convId,
                    updatedAt: Date(),
                    fromSessionStart: msg.event == "SessionStart"
                )
                AgentProcessScanner.invalidateOpenHandlesCache(for: agentPid)
            }

            if source == .cli {
                let msgSocket = msg.tmuxSocket.flatMap {
                    AgentProcessScanner.parseTmuxSocket($0) ?? AgentProcessScanner.canonicalPath($0)
                }
                let msgPane = msg.tmuxPane?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let paneKey = AgentProcessScanner.tmuxPaneKey(socket: msgSocket, pane: msgPane) {
                    convByTmuxPane[paneKey] = convId
                } else if let agentPid = resolvedAgentPid,
                          let agent = AgentProcessScanner.liveCLIAgents().first(where: { $0.pid == agentPid }),
                          let paneKey = AgentProcessScanner.tmuxPaneKey(socket: agent.tmuxSocket, pane: agent.tmuxPane) {
                    convByTmuxPane[paneKey] = convId
                }
            }

            if source == .cli, let rawOverride = msg.autoCompactOverride {
                let trimmed = rawOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                hookAutoCompactOverrideByConv[convId] = trimmed
                activeHookAutoCompactOverrideBySource[source] = trimmed
            }
        }
        if msg.event == "SessionStart" || msg.event == "PreInvocation" {
            hookLastEventAtBySource[source] = eventDate
        }

        if !convId.isEmpty {
            var records = hookTimingsByConv[convId] ?? []
            switch msg.event {
            case "PreInvocation":
                records.append(HookTimingRecord(
                    invocationNum: msg.invocationNum,
                    initialNumSteps: msg.initialNumSteps,
                    preInvocationMs: msg.tsMs,
                    postInvocationMs: nil,
                    stopMs: nil,
                    modelName: msg.modelName
                ))
                if records.count > 40 {
                    records.removeFirst(records.count - 40)
                }
                generatingStartByConv[convId] = eventDate
            case "PostInvocation":
                if let idx = records.lastIndex(where: { $0.invocationNum == msg.invocationNum || $0.postInvocationMs == nil }) {
                    records[idx].postInvocationMs = msg.tsMs
                }
            case "Stop":
                if let idx = records.lastIndex(where: { $0.stopMs == nil }) {
                    records[idx].stopMs = msg.tsMs
                }
                generatingStartByConv.removeValue(forKey: convId)
            case "SessionStart":
                generatingStartByConv.removeValue(forKey: convId)
            default:
                break
            }
            hookTimingsByConv[convId] = records
        }

        scheduleTimer()
        if source == .cli {
            tmuxFocusMonitor.probeNow(force: true)
        }
        refreshNow(scanConversations: true)
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        let interval: TimeInterval
        if !state.isVisible && generatingStartByConv.isEmpty {
            interval = 4.0
        } else {
            interval = 0.35
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow(scanConversations: false)
            }
        }
        updateTmuxPollingState()
    }

    private func updateTmuxPollingState() {
        guard state.isVisible,
              state.pinnedConversationId == nil,
              state.sourceMode != .desktop else {
            tmuxFocusMonitor.setActive(false)
            return
        }
        let trackingCLI = state.sourceMode == .cli
            || focusSources.isEmpty
            || focusSources.contains(.cli)
        guard trackingCLI else {
            tmuxFocusMonitor.setActive(false)
            return
        }
        let hasTmuxAgents = AgentProcessScanner.liveCLIAgents().contains { $0.tmuxSocket != nil }
        tmuxFocusMonitor.setActive(hasTmuxAgents)
    }

    private func handleTmuxSnapshotChanged() {
        let agents = AgentProcessScanner.liveCLIAgents()
        let selection = resolveFocusedTmuxSelection(agents: agents, allowRescan: true)
        let nextKey = selection.map {
            TmuxFocusKey(socket: $0.socket, paneId: $0.paneId, agentPid: $0.agent?.pid)
        }
        if let prev = lastObservedTmuxFocus, let next = nextKey, prev != next {
            lastTmuxFocusChangedAt = Date()
            if let pid = next.agentPid {
                AgentProcessScanner.invalidateOpenHandlesCache(for: pid)
            }
        }
        lastObservedTmuxFocus = nextKey
        refreshNow(scanConversations: false)
    }

    func refreshNow(scanConversations: Bool) {
        quotaClient?.loadFromDiskIfNewer()
        scanAnnotationsFast()

        let now = Date()
        if scanConversations || now.timeIntervalSince(lastConversationScanAt) >= 4.0 {
            lastConversationScanAt = now
            refreshRecentConversations()
        }

        let target = resolveTargetTranscript()
        if state.activeSource != target.source {
            state.activeSource = target.source
        }
        if target.conversationId != activeConversationId || target.path != activePath {
            switchToTranscript(path: target.path, conversationId: target.conversationId)
        } else if !activePath.isEmpty {
            readAppendedBytes(liveArrivalMs: now.timeIntervalSince1970 * 1000.0)
        }

        recomputeMetrics()
    }

    // MARK: - Annotations (`last_user_view_time`) Tracking

    private func startAnnotationsDirWatch() {
        for source in AgentSource.allCases where annotationWatches[source] == nil {
            let fd = open(source.annotationsDir.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let watch = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename],
                queue: DispatchQueue.main
            )
            watch.setEventHandler { [weak self] in
                self?.refreshNow(scanConversations: false)
            }
            watch.setCancelHandler {
                close(fd)
            }
            annotationWatches[source] = watch
            watch.resume()
        }
    }

    private func stopAnnotationsDirWatch() {
        for watch in annotationWatches.values {
            watch.cancel()
        }
        annotationWatches.removeAll()
    }

    private func scanAnnotationsFast() {
        var liveIds = Set<String>()
        for source in AgentSource.allCases {
            scanAnnotations(of: source, liveIds: &liveIds)
        }
        for oldKey in annotationCache.keys where !liveIds.contains(oldKey) {
            annotationCache.removeValue(forKey: oldKey)
        }
    }

    private func scanAnnotations(of source: AgentSource, liveIds: inout Set<String>) {
        let fm = FileManager.default
        let dirPath = source.annotationsDir.path
        guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

        for file in files where file.hasSuffix(".pbtxt") {
            let convId = String(file.dropLast(6))
            guard !convId.isEmpty else { continue }
            liveIds.insert(convId)

            let fullPath = "\(dirPath)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let mtime = attrs[.modificationDate] as? Date else {
                continue
            }

            if let cached = annotationCache[convId],
               abs(cached.mtime.timeIntervalSince(mtime)) < 0.001 {
                continue
            }

            if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                let parsedTitle = Self.parsePbtxtTitle(content)
                let viewTime = Self.parseLastUserViewTime(content)
                let entry = AnnotationEntry(
                    conversationId: convId,
                    source: source,
                    mtime: mtime,
                    title: parsedTitle,
                    lastUserViewTime: viewTime
                )
                annotationCache[convId] = entry
                if let parsedTitle, !parsedTitle.isEmpty {
                    cachedTitles[convId] = parsedTitle
                    if convId == activeConversationId {
                        state.conversationTitle = parsedTitle
                    }
                }
            }
        }
    }

    /// Desktop only: the agy CLI never writes `last_user_view_time`.
    private func resolveMostRecentlyViewedConversation() -> (id: String, viewTime: Double)? {
        let desktopEntries = annotationCache.values.filter { $0.source == .desktop }
        guard let maxVt = desktopEntries.compactMap(\.lastUserViewTime).max() else {
            return nil
        }

        // Only re-evaluate when a strictly newer view timestamp arrives, or on initial startup.
        if !currentAutoViewedId.isEmpty && maxVt <= lastHandledViewTime + 0.0005 {
            if let existing = annotationCache[currentAutoViewedId], let vt = existing.lastUserViewTime {
                return (currentAutoViewedId, vt)
            }
        }

        // Antigravity often writes the exact same `last_user_view_time` to both the conversation
        // the user just left AND the conversation the user just entered. Collect all tied entries
        // within 150ms of maxVt and exclude the currently active conversation to pick the destination.
        let tied = desktopEntries.filter { entry in
            guard let vt = entry.lastUserViewTime else { return false }
            return (maxVt - vt) <= 0.15
        }
        guard !tied.isEmpty else { return nil }

        let chosen: AnnotationEntry
        if tied.count == 1 {
            chosen = tied[0]
        } else {
            let switchedCandidates = tied.filter { $0.conversationId != activeConversationId }
            let pool = switchedCandidates.isEmpty ? tied : switchedCandidates
            chosen = pool.sorted { lhs, rhs in
                let lVt = lhs.lastUserViewTime ?? 0
                let rVt = rhs.lastUserViewTime ?? 0
                if abs(lVt - rVt) > 0.0005 {
                    return lVt > rVt
                }
                if abs(lhs.mtime.timeIntervalSince(rhs.mtime)) > 0.001 {
                    return lhs.mtime > rhs.mtime
                }
                let lMtime = transcriptMtime(for: lhs.conversationId)
                let rMtime = transcriptMtime(for: rhs.conversationId)
                if lMtime != rMtime {
                    return lMtime > rMtime
                }
                return lhs.conversationId < rhs.conversationId
            }.first!
        }

        lastHandledViewTime = maxVt
        currentAutoViewedId = chosen.conversationId
        return (chosen.conversationId, chosen.lastUserViewTime ?? maxVt)
    }

    private func transcriptMtime(for conversationId: String) -> TimeInterval {
        let p = transcriptPath(for: conversationId)
        guard !p.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let d = attrs[.modificationDate] as? Date else {
            return 0
        }
        return d.timeIntervalSince1970
    }

    private static let viewTimeRegex = try! NSRegularExpression(
        pattern: #"last_user_view_time\s*:\s*\{[^}]*seconds\s*:\s*(\d+)(?:[^}]*nanos\s*:\s*(\d+))?[^}]*\}"#
    )

    private static let titleRegex = try! NSRegularExpression(
        pattern: #"title\s*:\s*"((?:[^"\\]|\\.)*)""#
    )

    private static func parseLastUserViewTime(_ content: String) -> Double? {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = viewTimeRegex.firstMatch(in: content, range: range),
              match.range(at: 1).location != NSNotFound,
              let secs = Double(ns.substring(with: match.range(at: 1))) else {
            return nil
        }
        var nanos = 0.0
        if match.range(at: 2).location != NSNotFound,
           let n = Double(ns.substring(with: match.range(at: 2))) {
            nanos = n
        }
        return secs + nanos / 1_000_000_000.0
    }

    private static func parsePbtxtTitle(_ content: String) -> String? {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = titleRegex.firstMatch(in: content, range: range),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        let raw = ns.substring(with: match.range(at: 1))
        let unescaped = unescapePbtxtString(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return unescaped.isEmpty ? nil : unescaped
    }

    private static func unescapePbtxtString(_ raw: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next >= "0" && next <= "7" {
                    var octal = ""
                    var j = i + 1
                    while j < chars.count && j < i + 4 && chars[j] >= "0" && chars[j] <= "7" {
                        octal.append(chars[j])
                        j += 1
                    }
                    if let val = UInt8(octal, radix: 8) {
                        bytes.append(val)
                        i = j
                        continue
                    }
                }
                switch next {
                case "n": bytes.append(0x0A)
                case "r": bytes.append(0x0D)
                case "t": bytes.append(0x09)
                case "\"": bytes.append(0x22)
                case "\\": bytes.append(0x5C)
                default: bytes.append(contentsOf: String(next).utf8)
                }
                i += 2
            } else {
                bytes.append(contentsOf: String(chars[i]).utf8)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Seed, Calibration, and Recent Conversations

    private func loadRuntimeStateSeed() {
        for source in AgentSource.allCases {
            guard let data = try? Data(contentsOf: source.runtimeStateURL),
                  let runtime = try? JSONDecoder().decode(RuntimeStateFile.self, from: data) else {
                continue
            }
            if let timings = runtime.timings {
                for (convId, records) in timings {
                    hookTimingsByConv[convId] = records
                    sourceByConv[convId] = source
                }
            }
            if let overrides = runtime.autoCompactOverrides {
                for (convId, val) in overrides {
                    hookAutoCompactOverrideByConv[convId] = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if source == .cli, let panes = runtime.tmuxPanes {
                for (paneKey, convId) in panes where !paneKey.isEmpty && !convId.isEmpty {
                    let parts = paneKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2,
                       let normalizedKey = AgentProcessScanner.tmuxPaneKey(
                           socket: String(parts[0]),
                           pane: String(parts[1])
                       ) {
                        convByTmuxPane[normalizedKey] = convId
                        sourceByConv[convId] = .cli
                    }
                }
            }
            if let activeOverride = runtime.activeAutoCompactOverride {
                activeHookAutoCompactOverrideBySource[source] = activeOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let lastEventAt = runtime.lastEventMs.map { Date(timeIntervalSince1970: $0 / 1000.0) }
            if let lastEventAt {
                hookLastEventAtBySource[source] = lastEventAt
            }
            guard let conv = runtime.activeConversationId, !conv.isEmpty else { continue }
            hookActiveConvBySource[source] = conv
            sourceByConv[conv] = source
            if let model = runtime.activeModelName, !model.isEmpty {
                hookModelByConv[conv] = model
            }
            if runtime.isGenerating == true, let lastEventAt,
               Date().timeIntervalSince(lastEventAt) < 120 {
                generatingStartByConv[conv] = lastEventAt
            }
        }
    }

    private func calibrateCompactionThresholdsAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var calibrated: [AgentSource: [String: Int]] = [:]
            for source in AgentSource.allCases {
                let medians = Self.calibrateThresholds(brainPath: source.brainDir.path)
                if !medians.isEmpty {
                    calibrated[source] = medians
                }
            }

            Task { @MainActor [weak self] in
                guard let self, !calibrated.isEmpty else { return }
                self.observedThresholds = calibrated
                self.recomputeMetrics()
            }
        }
    }

    /// Median pre-compaction context per model family, from recent CHECKPOINT history.
    private nonisolated static func calibrateThresholds(brainPath: String) -> [String: Int] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: brainPath) else { return [:] }

        var filesWithMtime: [(String, Date)] = []
        for entry in entries {
            let tPath = "\(brainPath)/\(entry)/.system_generated/logs/transcript.jsonl"
            if let attrs = try? fm.attributesOfItem(atPath: tPath),
               let mtime = attrs[.modificationDate] as? Date {
                filesWithMtime.append((tPath, mtime))
            }
        }
        filesWithMtime.sort { $0.1 > $1.1 }

        var samplesByFamily: [String: [Int]] = [:]
        for (path, _) in filesWithMtime.prefix(25) {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var lastModel = ""
            var lastCtx = 0
            for line in content.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "PLANNER_RESPONSE" {
                    if let m = obj["model"] as? String, !m.isEmpty {
                        lastModel = m
                    }
                    let inp = (obj["input_tokens"] as? Int) ?? 0
                    let cache = (obj["cache_read_tokens"] as? Int) ?? 0
                    lastCtx = inp + cache
                } else if type == "CHECKPOINT" {
                    let inp = (obj["input_tokens"] as? Int) ?? 0
                    let cache = (obj["cache_read_tokens"] as? Int) ?? 0
                    let ckptCtx = inp + cache
                    let pre = max(ckptCtx, lastCtx)
                    if pre > 20_000 && !lastModel.isEmpty {
                        let maxWindow = ModelCatalog.spec(for: lastModel, observedThresholds: [:]).contextWindow
                        if pre <= maxWindow {
                            let fam = ModelCatalog.familyKey(for: lastModel)
                            samplesByFamily[fam, default: []].append(pre)
                        }
                    }
                }
            }
        }

        var medians: [String: Int] = [:]
        for (fam, values) in samplesByFamily where !values.isEmpty {
            let sorted = values.sorted()
            medians[fam] = sorted[sorted.count / 2]
        }
        return medians
    }

    private func refreshRecentConversations() {
        let fm = FileManager.default
        var candidates: [ConversationCandidate] = []
        var newest: [AgentSource: (id: String, path: String, mtime: Date)] = [:]

        for source in AgentSource.allCases {
            let brainPath = source.brainDir.path
            guard let dirs = try? fm.contentsOfDirectory(atPath: brainPath) else { continue }
            for dir in dirs {
                // The CLI also keeps subagent runs under brain/. Only conversations the
                // user opened get an annotation file, fire hooks, or are locked by a live agy.
                if source == .cli, annotationCache[dir] == nil, hookTimingsByConv[dir] == nil,
                   hookActiveConvBySource[.cli] != dir, agentPidByConv[dir] == nil {
                    continue
                }
                let tPath = "\(brainPath)/\(dir)/.system_generated/logs/transcript.jsonl"
                guard let attrs = try? fm.attributesOfItem(atPath: tPath),
                      let mtime = attrs[.modificationDate] as? Date else {
                    continue
                }
                sourceByConv[dir] = source
                if mtime > (newest[source]?.mtime ?? .distantPast) {
                    newest[source] = (dir, tPath, mtime)
                }
                let viewDate = annotationCache[dir]?.lastUserViewTime.map { Date(timeIntervalSince1970: $0) }
                let sortTime = viewDate.map { max($0, mtime) } ?? mtime
                candidates.append(ConversationCandidate(id: dir, path: tPath, sortTime: sortTime, source: source))
            }
        }
        candidates.sort { $0.sortTime > $1.sortTime }
        newestTranscriptBySource = newest

        if Date().timeIntervalSince(lastTitleFetchAt) > 30,
           quotaClient?.hasLiveCredentials == true {
            lastTitleFetchAt = Date()
            quotaClient?.fetchConversationTitles { [weak self] fetched in
                guard let self, !fetched.isEmpty else { return }
                for (k, v) in fetched {
                    self.cachedTitles[k] = v
                }
                self.updateConversationChoices(candidates: candidates)
            }
        }

        updateConversationChoices(candidates: candidates)
    }

    private func updateConversationChoices(candidates: [ConversationCandidate]) {
        var choices: [ConversationChoice] = []
        for item in candidates.prefix(10) {
            let title = cachedTitles[item.id]
                ?? annotationCache[item.id]?.title
                ?? extractTitleFromTranscriptHead(path: item.path)
                ?? String(item.id.prefix(8))
            choices.append(ConversationChoice(
                id: item.id,
                title: title,
                updatedAt: item.sortTime,
                transcriptPath: item.path,
                modelId: nil,
                source: item.source
            ))
        }
        state.recentConversations = choices
    }

    private func extractTitleFromTranscriptHead(path: String) -> String? {
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let chunk = fh.readData(ofLength: 16 * 1024)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "USER_INPUT",
                  var content = obj["content"] as? String else {
                continue
            }
            if content.contains("<USER_REQUEST>"),
               let start = content.range(of: "<USER_REQUEST>"),
               let end = content.range(of: "</USER_REQUEST>") {
                content = String(content[start.upperBound..<end.lowerBound])
            }
            let cleaned = content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned.count > 34 ? String(cleaned.prefix(34)) + "…" : cleaned
            }
        }
        return nil
    }

    private func transcriptPath(for conversationId: String) -> String {
        var order = AgentSource.allCases
        if let known = sourceByConv[conversationId] {
            order = [known] + order.filter { $0 != known }
        }
        for source in order {
            let logsDir = source.brainDir
                .appendingPathComponent(conversationId)
                .appendingPathComponent(".system_generated/logs")
            for name in ["transcript.jsonl", "transcript_full.jsonl"] {
                let path = logsDir.appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: path) {
                    sourceByConv[conversationId] = source
                    return path
                }
            }
        }
        return ""
    }

    /// Which front end to display when no conversation is pinned.
    private func resolveActiveSource() -> AgentSource {
        if let forced = state.sourceMode {
            return forced
        }
        if focusSources.count == 1, let only = focusSources.first {
            return only
        }
        // No host window has been frontmost yet, or one app shows both (agy running in
        // Antigravity's own terminal): follow whichever was used last.
        return lastActivity(of: .cli) > lastActivity(of: .desktop) ? .cli : .desktop
    }

    private func lastActivity(of source: AgentSource) -> Date {
        var latest = max(
            hookLastEventAtBySource[source] ?? .distantPast,
            newestTranscriptBySource[source]?.mtime ?? .distantPast
        )
        if source == .cli {
            latest = max(latest, lastTmuxFocusChangedAt)
        }
        if source == .desktop,
           let viewed = annotationCache.values
               .filter({ $0.source == .desktop })
               .compactMap(\.lastUserViewTime).max() {
            latest = max(latest, Date(timeIntervalSince1970: viewed))
        }
        return latest
    }

    private func resolveTargetTranscript() -> (path: String, conversationId: String, source: AgentSource) {
        // 1. User manually pinned a specific conversation in the Menu Bar
        if let pinned = state.pinnedConversationId, !pinned.isEmpty {
            let path = transcriptPath(for: pinned)
            return (path, pinned, sourceByConv[pinned] ?? resolveActiveSource())
        }

        let source = resolveActiveSource()
        let target = source == .cli ? resolveCLITarget() : resolveDesktopTarget()
        return (target.path, target.conversationId, source)
    }

    private func resolveDesktopTarget() -> (path: String, conversationId: String) {
        let hookConvId = hookActiveConvBySource[.desktop] ?? ""

        // Primary source: Antigravity's `annotations/<id>.pbtxt` `last_user_view_time`
        if let viewed = resolveMostRecentlyViewedConversation() {
            // Only prefer a brand-new hook conversation if it has no annotation view time yet
            // AND started strictly after the last viewed conversation.
            if !hookConvId.isEmpty,
               hookConvId != viewed.id,
               annotationCache[hookConvId]?.lastUserViewTime == nil,
               (hookLastEventAtBySource[.desktop] ?? .distantPast).timeIntervalSince1970 > viewed.viewTime {
                return (transcriptPath(for: hookConvId), hookConvId)
            }
            return (transcriptPath(for: viewed.id), viewed.id)
        }

        // Fallback when no annotation files exist yet
        if !hookConvId.isEmpty {
            return (transcriptPath(for: hookConvId), hookConvId)
        }
        if let newest = newestTranscriptBySource[.desktop] {
            return (newest.path, newest.id)
        }
        return ("", "")
    }

    /// Resolves the active CLI session:
    /// 1. Live `agy` in the focused tmux pane / window / session (prevents background tasks from hijacking).
    /// 2. Live non-tmux `agy` hosted by the frontmost terminal app.
    /// 3. Most recent CLI hook or transcript on disk.
    private func resolveCLITarget() -> (path: String, conversationId: String) {
        let agents = AgentProcessScanner.liveCLIAgents()

        if let focused = resolveFocusedTmuxSelection(agents: agents, allowRescan: false),
           let agent = focused.agent,
           let convId = resolveConversationId(for: agent) {
            recordLiveAgentLink(agent: agent, conversationId: convId, paneIdOverride: focused.paneId)
            return (transcriptPath(for: convId), convId)
        }

        if let hostPid = focusHostPid {
            let nonTmuxInHost = agents.filter { $0.tmuxSocket == nil && $0.hostPids.contains(hostPid) }
            if let chosen = pickPreferredAgent(from: nonTmuxInHost),
               let convId = resolveConversationId(for: chosen) {
                recordLiveAgentLink(agent: chosen, conversationId: convId, paneIdOverride: nil)
                return (transcriptPath(for: convId), convId)
            }
        }

        if let hookConvId = hookActiveConvBySource[.cli], !hookConvId.isEmpty {
            let path = transcriptPath(for: hookConvId)
            let startedJustNow = Date().timeIntervalSince(hookLastEventAtBySource[.cli] ?? .distantPast) < 60
            // A new session fires SessionStart before its transcript file exists.
            if !path.isEmpty || startedJustNow {
                return (path, hookConvId)
            }
        }
        if let newest = newestTranscriptBySource[.cli] {
            return (newest.path, newest.id)
        }
        return ("", "")
    }

    private func recordLiveAgentLink(agent: AgentProcessScanner.CLIAgent, conversationId: String, paneIdOverride: String?) {
        sourceByConv[conversationId] = .cli
        agentPidByConv[conversationId] = agent.pid
        if let paneKey = AgentProcessScanner.tmuxPaneKey(socket: agent.tmuxSocket, pane: paneIdOverride ?? agent.tmuxPane) {
            convByTmuxPane[paneKey] = conversationId
        }
    }

    private func resolveFocusedTmuxSelection(
        agents: [AgentProcessScanner.CLIAgent],
        allowRescan: Bool
    ) -> FocusedTmuxSelection? {
        var currentAgents = agents
        var tmuxAgents = currentAgents.filter { $0.tmuxSocket != nil }

        // Optional instant IPC push hint (e.g. from tmux after-select-pane hook).
        if let hint = ipcTmuxFocusHint {
            if Date().timeIntervalSince(hint.receivedAt) <= 0.4 {
                let serverAgents = tmuxAgents.filter { $0.tmuxSocket == hint.socket }
                if let matched = pickPreferredAgent(from: serverAgents.filter { $0.tmuxPane == hint.paneId }) {
                    return FocusedTmuxSelection(socket: hint.socket, paneId: hint.paneId, agent: matched)
                }
            } else {
                ipcTmuxFocusHint = nil
            }
        }

        guard !tmuxAgents.isEmpty else { return nil }
        let liveSockets = Set(tmuxAgents.compactMap(\.tmuxSocket))
        let allClients: [(snapshot: TmuxServerSnapshot, client: TmuxClientInfo)] = tmuxFocusMonitor.snapshots.values
            .filter { liveSockets.contains($0.socket) }
            .flatMap { snap in snap.clients.map { (snap, $0) } }
        guard !allClients.isEmpty else { return nil }

        let chosenPair: (snapshot: TmuxServerSnapshot, client: TmuxClientInfo)?
        if let hostPid = focusHostPid {
            let hostMatches = allClients.filter {
                AgentProcessScanner.hostAppPid(of: $0.client.clientPid) == hostPid
            }
            if !hostMatches.isEmpty {
                chosenPair = bestTmuxClient(from: hostMatches)
            } else {
                let hasNonTmuxInFrontHost = currentAgents.contains {
                    $0.tmuxSocket == nil && $0.hostPids.contains(hostPid)
                }
                if hasNonTmuxInFrontHost {
                    return nil
                }
                chosenPair = bestTmuxClient(from: allClients)
            }
        } else {
            chosenPair = bestTmuxClient(from: allClients)
        }

        guard let (snapshot, activeClient) = chosenPair else { return nil }

        var serverAgents = tmuxAgents.filter { $0.tmuxSocket == snapshot.socket }

        // Priority 1: Focused tmux pane.
        var activePaneAgents = matchingAgents(
            paneId: activeClient.paneId,
            panePid: activeClient.panePid,
            in: serverAgents
        )
        if activePaneAgents.isEmpty && allowRescan {
            let paneKey = "\(snapshot.socket)|\(activeClient.paneId)"
            let now = Date()
            if paneKey != lastUnmatchedPaneRescanKey && now.timeIntervalSince(lastUnmatchedPaneRescanAt) >= 0.5 {
                lastUnmatchedPaneRescanKey = paneKey
                lastUnmatchedPaneRescanAt = now
                AgentProcessScanner.invalidateCache()
                currentAgents = AgentProcessScanner.liveCLIAgents(maxAge: 0)
                tmuxAgents = currentAgents.filter { $0.tmuxSocket != nil }
                serverAgents = tmuxAgents.filter { $0.tmuxSocket == snapshot.socket }
                activePaneAgents = matchingAgents(
                    paneId: activeClient.paneId,
                    panePid: activeClient.panePid,
                    in: serverAgents
                )
            }
        }
        if let chosen = pickPreferredAgent(from: activePaneAgents) {
            return FocusedTmuxSelection(socket: snapshot.socket, paneId: activeClient.paneId, agent: chosen)
        }

        // Priority 2: Companion `agy` pane in the same active tmux window (e.g. when a sidebar
        // pane like tmux-arbor or a shell split in the same window is temporarily focused).
        let windowPanes = snapshot.panes.filter {
            $0.sessionId == activeClient.sessionId && $0.windowId == activeClient.windowId
        }
        let windowMatches: [(pane: TmuxPaneInfo, agent: AgentProcessScanner.CLIAgent)] = windowPanes.flatMap { pane in
            matchingAgents(paneId: pane.paneId, panePid: pane.panePid, in: serverAgents).map { (pane, $0) }
        }
        if let chosen = pickPreferredPaneAgent(from: windowMatches) {
            return FocusedTmuxSelection(socket: snapshot.socket, paneId: chosen.pane.paneId, agent: chosen.agent)
        }

        // Priority 3: `agy` pane in the same active tmux session.
        let sessionPanes = snapshot.panes.filter { $0.sessionId == activeClient.sessionId }
        let sessionMatches: [(pane: TmuxPaneInfo, agent: AgentProcessScanner.CLIAgent)] = sessionPanes.flatMap { pane in
            matchingAgents(paneId: pane.paneId, panePid: pane.panePid, in: serverAgents).map { (pane, $0) }
        }
        if let chosen = pickPreferredPaneAgent(from: sessionMatches) {
            return FocusedTmuxSelection(socket: snapshot.socket, paneId: chosen.pane.paneId, agent: chosen.agent)
        }

        return FocusedTmuxSelection(socket: snapshot.socket, paneId: activeClient.paneId, agent: nil)
    }

    private func bestTmuxClient(
        from candidates: [(snapshot: TmuxServerSnapshot, client: TmuxClientInfo)]
    ) -> (snapshot: TmuxServerSnapshot, client: TmuxClientInfo)? {
        candidates.max { lhs, rhs in
            if lhs.client.isFocused != rhs.client.isFocused {
                return !lhs.client.isFocused && rhs.client.isFocused
            }
            if lhs.client.activity != rhs.client.activity {
                return lhs.client.activity < rhs.client.activity
            }
            return lhs.client.clientPid < rhs.client.clientPid
        }
    }

    private func matchingAgents(
        paneId: String,
        panePid: pid_t,
        in serverAgents: [AgentProcessScanner.CLIAgent]
    ) -> [AgentProcessScanner.CLIAgent] {
        serverAgents.filter { agent in
            if let agentPane = agent.tmuxPane, agentPane == paneId {
                return true
            }
            return panePid > 1 && AgentProcessScanner.isDescendant(agent.pid, of: panePid)
        }
    }

    private func pickPreferredAgent(
        from agents: [AgentProcessScanner.CLIAgent]
    ) -> AgentProcessScanner.CLIAgent? {
        guard !agents.isEmpty else { return nil }
        if agents.count == 1 { return agents[0] }
        return agents.max { lhs, rhs in
            agentActivityRank(lhs) < agentActivityRank(rhs)
        }
    }

    private func pickPreferredPaneAgent(
        from pairs: [(pane: TmuxPaneInfo, agent: AgentProcessScanner.CLIAgent)]
    ) -> (pane: TmuxPaneInfo, agent: AgentProcessScanner.CLIAgent)? {
        guard !pairs.isEmpty else { return nil }
        if pairs.count == 1 { return pairs[0] }
        return pairs.max { lhs, rhs in
            let lScore = agentActivityRank(lhs.agent)
            let rScore = agentActivityRank(rhs.agent)
            if lScore != rScore {
                return lScore < rScore
            }
            if lhs.pane.isActive != rhs.pane.isActive {
                return !lhs.pane.isActive && rhs.pane.isActive
            }
            return lhs.agent.pid < rhs.agent.pid
        }
    }

    private func agentActivityRank(_ agent: AgentProcessScanner.CLIAgent) -> (Int, TimeInterval) {
        let convId = resolveConversationId(for: agent)
        let isCurrentlyDisplayed = (convId != nil && convId == activeConversationId) ? 1 : 0
        let hookTime = convByAgentPid[agent.pid]?.updatedAt.timeIntervalSince1970 ?? 0
        let mtime = convId.map { transcriptMtime(for: $0) } ?? 0
        return (isCurrentlyDisplayed, max(hookTime, mtime))
    }

    private func resolveConversationId(for agent: AgentProcessScanner.CLIAgent) -> String? {
        let hookLink = convByAgentPid[agent.pid]
        let handles = AgentProcessScanner.openConversationHandles(for: agent.pid)

        // During the brief startup window right after SessionStart, prefer the hook's
        // new conversation ID if the process hasn't opened its lock file yet.
        if let hookLink, hookLink.fromSessionStart,
           Date().timeIntervalSince(hookLink.updatedAt) < 2.0,
           handles.lockIds.isEmpty {
            return hookLink.conversationId
        }

        let preferred: Set<String>
        if !handles.lockIds.isEmpty {
            preferred = handles.lockIds
        } else if !handles.dbIds.isEmpty {
            preferred = handles.dbIds
        } else {
            preferred = handles.brainIds
        }

        if !preferred.isEmpty {
            if preferred.count == 1, let only = preferred.first {
                return only
            }
            if let hookConv = hookLink?.conversationId, preferred.contains(hookConv) {
                return hookConv
            }
            return preferred.max { lhs, rhs in
                let lm = transcriptMtime(for: lhs)
                let rm = transcriptMtime(for: rhs)
                if lm != rm { return lm < rm }
                return lhs > rhs
            }
        }

        if let hookConv = hookLink?.conversationId, !hookConv.isEmpty {
            return hookConv
        }
        if let paneKey = AgentProcessScanner.tmuxPaneKey(socket: agent.tmuxSocket, pane: agent.tmuxPane),
           let paneConv = convByTmuxPane[paneKey], !paneConv.isEmpty {
            return paneConv
        }
        return nil
    }

    // MARK: - Transcript Reading & VNODE Watch

    private func switchToTranscript(path: String, conversationId: String) {
        let isSameTarget = (conversationId == activeConversationId && path == activePath)
        if isSameTarget {
            // Re-open after rename/delete: discard cached state so the file is re-read cleanly.
            transcriptCache.removeValue(forKey: conversationId)
        } else if !activeConversationId.isEmpty, !activePath.isEmpty {
            transcriptCache[activeConversationId] = CachedTranscript(
                path: activePath,
                inode: activeInode,
                readOffset: readOffset,
                lineRemainder: lineRemainder,
                parsedSteps: parsedSteps,
                lastUsedAt: Date()
            )
            if transcriptCache.count > 16 {
                let oldestKeys = transcriptCache
                    .sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }
                    .dropFirst(16)
                    .map(\.key)
                for key in oldestKeys {
                    transcriptCache.removeValue(forKey: key)
                }
            }
        }

        stopVnodeWatch()
        activePath = path
        activeConversationId = conversationId

        if !isSameTarget, !path.isEmpty,
           let cached = transcriptCache[conversationId], cached.path == path {
            activeInode = cached.inode
            readOffset = cached.readOffset
            lineRemainder = cached.lineRemainder
            parsedSteps = cached.parsedSteps
            transcriptCache[conversationId]?.lastUsedAt = Date()
        } else {
            activeInode = 0
            readOffset = 0
            lineRemainder = ""
            parsedSteps = []
        }

        state.conversationId = conversationId
        NSLog("[AgyHUD] tracking %@ conversation %@", state.activeSource.rawValue, conversationId.isEmpty ? "(none)" : conversationId)
        if !conversationId.isEmpty {
            if let cached = cachedTitles[conversationId] ?? annotationCache[conversationId]?.title {
                cachedTitles[conversationId] = cached
                state.conversationTitle = cached
            } else if let extracted = extractTitleFromTranscriptHead(path: path) {
                cachedTitles[conversationId] = extracted
                state.conversationTitle = extracted
            } else {
                state.conversationTitle = String(conversationId.prefix(8))
            }
        } else {
            state.conversationTitle = "等待对话..."
        }

        guard !path.isEmpty else { return }
        readAppendedBytes(liveArrivalMs: nil)
        startVnodeWatch(path: path)
    }

    private func startVnodeWatch(path: String) {
        stopVnodeWatch()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.switchToTranscript(path: self.activePath, conversationId: self.activeConversationId)
            } else {
                self.readAppendedBytes(liveArrivalMs: Date().timeIntervalSince1970 * 1000.0)
            }
            self.recomputeMetrics()
        }
        source.setCancelHandler {
            close(fd)
        }
        vnodeSource = source
        source.resume()
    }

    private func stopVnodeWatch() {
        vnodeSource?.cancel()
        vnodeSource = nil
    }

    private func readAppendedBytes(liveArrivalMs: Double?) {
        guard !activePath.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: activePath),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value else {
            return
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        if inode != activeInode || fileSize < readOffset {
            activeInode = inode
            readOffset = 0
            lineRemainder = ""
            parsedSteps = []
        }

        if fileSize == readOffset {
            return
        }

        guard let fh = FileHandle(forReadingAtPath: activePath) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: readOffset)
        } catch {
            return
        }

        let deltaData = fh.readDataToEndOfFile()
        guard !deltaData.isEmpty,
              let chunk = String(data: deltaData, encoding: .utf8) else {
            return
        }

        readOffset += UInt64(deltaData.count)
        let combined = lineRemainder + chunk
        var lines = combined.components(separatedBy: "\n")
        if combined.hasSuffix("\n") {
            lineRemainder = ""
            if lines.last == "" { lines.removeLast() }
        } else {
            lineRemainder = lines.removeLast()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let step = parseStep(obj, liveArrivalMs: liveArrivalMs) else {
                continue
            }
            if let last = parsedSteps.last, last.stepIndex == step.stepIndex {
                parsedSteps[parsedSteps.count - 1] = step
            } else {
                parsedSteps.append(step)
            }
        }
    }

    private func parseStep(_ obj: [String: Any], liveArrivalMs: Double?) -> ParsedStep? {
        guard let stepIdx = obj["step_index"] as? Int,
              let type = obj["type"] as? String else {
            return nil
        }
        let status = (obj["status"] as? String) ?? ""
        let createdAt = HUDFormatters.parseISO(obj["created_at"] as? String)
        let model = obj["model"] as? String
        let inputTokens = (obj["input_tokens"] as? Int) ?? 0
        let cacheReadTokens = (obj["cache_read_tokens"] as? Int) ?? 0
        let outputTokens = (obj["output_tokens"] as? Int) ?? 0
        let content = obj["content"] as? String
        let contentLength = content?.count ?? 0
        let toolCalls = obj["tool_calls"] as? [Any]
        let hasToolCalls = !(toolCalls?.isEmpty ?? true)

        let obsMs: Double? = (type == "PLANNER_RESPONSE" && status == "DONE") ? liveArrivalMs : nil
        return ParsedStep(
            stepIndex: stepIdx,
            type: type,
            status: status,
            createdAt: createdAt,
            model: model,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            contentLength: contentLength,
            hasToolCalls: hasToolCalls,
            observedDoneMs: obsMs
        )
    }

    // MARK: - Metrics Calculation

    private func recomputeMetrics() {
        // Per-conversation generating indicator
        if let started = generatingStartByConv[activeConversationId] {
            let agentExited = agentPidByConv[activeConversationId].map { !AgentProcessScanner.isAlive($0) } ?? false
            if Date().timeIntervalSince(started) > 180 || agentExited {
                generatingStartByConv.removeValue(forKey: activeConversationId)
                state.isGenerating = false
                state.generatingStartedAt = nil
            } else {
                state.isGenerating = true
                state.generatingStartedAt = started
            }
        } else {
            state.isGenerating = false
            state.generatingStartedAt = nil
        }

        let planners = parsedSteps.filter { $0.type == "PLANNER_RESPONSE" }
        let latestPlanner = planners.last

        let resolvedModelId: String
        if let m = latestPlanner?.model, !m.isEmpty {
            resolvedModelId = m
        } else if let hookModel = hookModelByConv[activeConversationId], !hookModel.isEmpty {
            resolvedModelId = hookModel
        } else {
            resolvedModelId = ""
        }

        let modelChanged = (resolvedModelId != state.modelId)
        state.modelId = resolvedModelId
        let calibrated = observedThresholds[state.activeSource] ?? [:]
        let spec = ModelCatalog.spec(for: resolvedModelId, observedThresholds: calibrated)
        state.modelDisplayName = spec.displayName
        state.contextWindow = spec.contextWindow

        if state.activeSource == .cli,
           let rawOverride = resolveCLIAutoCompactOverride(for: activeConversationId),
           let overrideTokens = ModelCatalog.parseAutoCompactOverride(rawOverride, contextWindow: spec.contextWindow) {
            state.compactionThreshold = overrideTokens
            state.thresholdSource = "override"
            state.thresholdOverrideLabel = rawOverride
        } else {
            state.compactionThreshold = spec.defaultThreshold
            state.thresholdSource = calibrated[spec.familyKey] != nil ? "calibrated" : "default"
            state.thresholdOverrideLabel = nil
        }

        if modelChanged {
            quotaClient?.regroupForActiveModel()
        }

        // Context metrics
        if let p = latestPlanner {
            let ctx = p.inputTokens + p.cacheReadTokens
            state.contextTokens = ctx
            state.cacheReadTokens = p.cacheReadTokens
            state.freshInputTokens = p.inputTokens
            state.lastOutputTokens = p.outputTokens
            state.cacheHitRate = ctx > 0 ? Double(p.cacheReadTokens) / Double(ctx) : 0

            if planners.count >= 2 {
                let prev = planners[planners.count - 2]
                let prevCtx = prev.inputTokens + prev.cacheReadTokens
                state.contextDelta = ctx - prevCtx
            } else {
                state.contextDelta = ctx
            }
        } else {
            state.contextTokens = 0
            state.cacheReadTokens = 0
            state.freshInputTokens = 0
            state.lastOutputTokens = 0
            state.cacheHitRate = 0
            state.contextDelta = 0
        }

        // Compaction events
        var compactions: [CompactionRecord] = []
        for (idx, step) in parsedSteps.enumerated() where step.type == "CHECKPOINT" {
            let prevPlanner = parsedSteps[0..<idx].last(where: { $0.type == "PLANNER_RESPONSE" })
            let nextPlanner = parsedSteps[(idx + 1)...].first(where: { $0.type == "PLANNER_RESPONSE" })
            let ckptCtx = step.inputTokens + step.cacheReadTokens
            let prevCtx = prevPlanner.map { $0.inputTokens + $0.cacheReadTokens } ?? 0
            let preTokens = max(ckptCtx, prevCtx)
            let postTokens = nextPlanner.map { $0.inputTokens + $0.cacheReadTokens }
            let summaryTokens = step.outputTokens > 0 ? step.outputTokens : max(1, step.contentLength / 4)

            compactions.append(CompactionRecord(
                stepIndex: step.stepIndex,
                preTokens: preTokens,
                postTokens: postTokens,
                summaryTokens: summaryTokens,
                timestamp: step.createdAt
            ))
        }
        state.allCompactions = compactions
        state.compactionCount = compactions.count
        state.lastCompaction = compactions.last

        // TPS calculations across completed PLANNER_RESPONSE turns
        let hookTimings = hookTimingsByConv[activeConversationId] ?? []
        var turnSpeeds: [(tps: Double, tokens: Int, duration: Double)] = []

        for (idx, step) in parsedSteps.enumerated() {
            guard step.type == "PLANNER_RESPONSE",
                  step.status == "DONE",
                  step.outputTokens > 0 else {
                continue
            }

            var dt: Double? = nil

            // Priority 1: Exact hook timing matched to this specific step (stepIndex + createdAt window)
            if let matchingHook = hookTimings.last(where: { hook in
                guard let preMs = hook.preInvocationMs else { return false }
                if let initSteps = hook.initialNumSteps {
                    let delta = step.stepIndex - initSteps
                    if delta < 0 || delta > 3 { return false }
                }
                if let created = step.createdAt {
                    if abs((preMs / 1000.0) - created.timeIntervalSince1970) > 6.0 {
                        return false
                    }
                }
                return true
            }), let preMs = matchingHook.preInvocationMs {
                if !step.hasToolCalls, let stopMs = matchingHook.stopMs, stopMs > preMs {
                    dt = (stopMs - preMs) / 1000.0
                } else if let obsMs = step.observedDoneMs, obsMs > preMs {
                    dt = (obsMs - preMs) / 1000.0
                }
            }

            // Priority 2: Transcript timestamp delta to immediate execution step ONLY
            // (NEVER measure against USER_INPUT or SYSTEM_MESSAGE, which include human reading/idle time!)
            if dt == nil, idx + 1 < parsedSteps.count {
                let nextStep = parsedSteps[idx + 1]
                if nextStep.type == "GENERIC" || nextStep.type == "CHECKPOINT",
                   let start = step.createdAt,
                   let end = nextStep.createdAt {
                    let diff = end.timeIntervalSince(start)
                    if diff >= 0.8 && diff <= 180.0 {
                        dt = diff
                    }
                }
            }

            // Priority 3: Live VNODE arrival timestamp for final text replies without a matching hook
            if dt == nil, !step.hasToolCalls,
               let obsMs = step.observedDoneMs,
               let start = step.createdAt {
                let diff = (obsMs / 1000.0) - start.timeIntervalSince1970
                if diff >= 0.4 && diff <= 180.0 {
                    dt = diff
                }
            }

            if let duration = dt, duration >= 0.4, duration <= 180.0 {
                let speed = Double(step.outputTokens) / duration
                if speed.isFinite && speed > 0 && speed <= 800.0 {
                    turnSpeeds.append((speed, step.outputTokens, duration))
                }
            }
        }

        if let last = turnSpeeds.last {
            state.lastTurnTps = last.tps
            state.lastTurnTokens = last.tokens
            state.lastTurnDurationSec = last.duration
            let totalTokens = turnSpeeds.reduce(0) { $0 + $1.tokens }
            let totalDuration = turnSpeeds.reduce(0.0) { $0 + $1.duration }
            state.avgTps = totalDuration > 0 ? Double(totalTokens) / totalDuration : nil
            state.peakTps = turnSpeeds.map(\.tps).max()
            state.recentTps = Array(turnSpeeds.suffix(14).map(\.tps))
        } else {
            state.lastTurnTps = nil
            state.lastTurnTokens = 0
            state.lastTurnDurationSec = nil
            state.avgTps = nil
            state.peakTps = nil
            state.recentTps = []
        }
    }

    private func resolveCLIAutoCompactOverride(for convId: String) -> String? {
        if !convId.isEmpty, let pid = agentPidByConv[convId] {
            let live = AgentProcessScanner.autoCompactOverride(for: pid)
            if live.found {
                return live.value
            }
        }
        if !convId.isEmpty, let fromHook = hookAutoCompactOverrideByConv[convId] {
            return fromHook.isEmpty ? nil : fromHook
        }
        if let fromLiveProcess = AgentProcessScanner.fallbackAutoCompactOverride() {
            return fromLiveProcess
        }
        if let active = activeHookAutoCompactOverrideBySource[.cli], !active.isEmpty {
            return active
        }
        return nil
    }
}
