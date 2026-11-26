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
        let textPreview: String?
        let observedDoneMs: Double?
    }

    private let state: HUDState
    private weak var quotaClient: QuotaClient?

    private var activePath: String = ""
    private var activeConversationId: String = ""
    private var activeInode: UInt64 = 0
    private var readOffset: UInt64 = 0
    private var lineRemainder: String = ""
    private var parsedSteps: [ParsedStep] = []

    private var vnodeSource: DispatchSourceFileSystemObject?
    private var vnodeFd: Int32 = -1
    private var pollTimer: Timer?
    private var lastConversationScanAt: Date = .distantPast
    private var lastTitleFetchAt: Date = .distantPast
    private var cachedTitles: [String: String] = [:]

    private var observedThresholds: [String: Int] = [:]
    private var hookTimingsByConv: [String: [HookTimingRecord]] = [:]
    private var hookActiveConvId: String = ""
    private var hookActiveTranscriptPath: String = ""
    private var hookActiveModel: String = ""
    private var hookLastEventAt: Date = .distantPast

    init(state: HUDState, quotaClient: QuotaClient) {
        self.state = state
        self.quotaClient = quotaClient
        loadRuntimeStateSeed()
        calibrateCompactionThresholdsAsync()
        refreshNow(scanConversations: true)
    }

    func start() {
        scheduleTimer()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopVnodeWatch()
    }

    func updatePollingCadence() {
        scheduleTimer()
    }

    func selectConversation(_ conversationId: String?) {
        state.updatePrefs { prefs in
            prefs.pinnedConversationId = conversationId
        }
        refreshNow(scanConversations: true)
    }

    func handleHookEvent(_ msg: HookIPCMessage) {
        let convId = msg.conversationId ?? ""
        if !convId.isEmpty {
            hookActiveConvId = convId
        }
        if let path = msg.transcriptPath, !path.isEmpty {
            hookActiveTranscriptPath = path
        }
        if let model = msg.modelName, !model.isEmpty {
            hookActiveModel = model
        }
        hookLastEventAt = Date(timeIntervalSince1970: msg.tsMs / 1000.0)

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
                if state.pinnedConversationId == nil || state.pinnedConversationId == convId {
                    state.isGenerating = true
                    state.generatingStartedAt = Date(timeIntervalSince1970: msg.tsMs / 1000.0)
                }
            case "PostInvocation":
                if let idx = records.lastIndex(where: { $0.invocationNum == msg.invocationNum || $0.postInvocationMs == nil }) {
                    records[idx].postInvocationMs = msg.tsMs
                }
            case "Stop":
                if let idx = records.lastIndex(where: { $0.stopMs == nil }) {
                    records[idx].stopMs = msg.tsMs
                }
                if state.pinnedConversationId == nil || state.pinnedConversationId == convId {
                    state.isGenerating = false
                    state.generatingStartedAt = nil
                }
            case "SessionStart":
                if state.pinnedConversationId == nil || state.pinnedConversationId == convId {
                    state.isGenerating = false
                    state.generatingStartedAt = nil
                }
            default:
                break
            }
            hookTimingsByConv[convId] = records
        }

        scheduleTimer()
        refreshNow(scanConversations: true)
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        let interval: TimeInterval
        if !state.isVisible && !state.isGenerating {
            interval = 4.0
        } else if state.isGenerating {
            interval = 0.5
        } else {
            interval = 1.5
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow(scanConversations: false)
            }
        }
    }

    func refreshNow(scanConversations: Bool) {
        quotaClient?.loadFromDiskIfNewer()

        let now = Date()
        if scanConversations || now.timeIntervalSince(lastConversationScanAt) >= 5.0 {
            lastConversationScanAt = now
            refreshRecentConversations()
        }

        let target = resolveTargetTranscript()
        if target.path != activePath {
            switchToTranscript(path: target.path, conversationId: target.conversationId)
        } else if !activePath.isEmpty {
            readAppendedBytes(liveArrivalMs: now.timeIntervalSince1970 * 1000.0)
        }

        recomputeMetrics()
    }

    private func loadRuntimeStateSeed() {
        guard let data = try? Data(contentsOf: AppPaths.runtimeStateURL),
              let runtime = try? JSONDecoder().decode(RuntimeStateFile.self, from: data) else {
            return
        }
        if let timings = runtime.timings {
            hookTimingsByConv = timings
        }
        if let conv = runtime.activeConversationId, !conv.isEmpty {
            hookActiveConvId = conv
        }
        if let path = runtime.activeTranscriptPath, !path.isEmpty {
            hookActiveTranscriptPath = path
        }
        if let model = runtime.activeModelName, !model.isEmpty {
            hookActiveModel = model
        }
        if let ms = runtime.lastEventMs {
            hookLastEventAt = Date(timeIntervalSince1970: ms / 1000.0)
        }
        if runtime.isGenerating == true,
           Date().timeIntervalSince(hookLastEventAt) < 120 {
            state.isGenerating = true
            state.generatingStartedAt = hookLastEventAt
        }
    }

    private func calibrateCompactionThresholdsAsync() {
        let brainPath = AppPaths.brainDir.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: brainPath) else { return }

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
                            let fam = ModelCatalog.familyKey(for: lastModel)
                            samplesByFamily[fam, default: []].append(pre)
                        }
                    }
                }
            }

            var medians: [String: Int] = [:]
            for (fam, values) in samplesByFamily where !values.isEmpty {
                let sorted = values.sorted()
                medians[fam] = sorted[sorted.count / 2]
            }

            Task { @MainActor [weak self] in
                guard let self, !medians.isEmpty else { return }
                self.observedThresholds = medians
                self.recomputeMetrics()
            }
        }
    }

    private func refreshRecentConversations() {
        let fm = FileManager.default
        let brainPath = AppPaths.brainDir.path
        guard let dirs = try? fm.contentsOfDirectory(atPath: brainPath) else { return }

        var candidates: [(id: String, path: String, mtime: Date)] = []
        for dir in dirs {
            let tPath = "\(brainPath)/\(dir)/.system_generated/logs/transcript.jsonl"
            if let attrs = try? fm.attributesOfItem(atPath: tPath),
               let mtime = attrs[.modificationDate] as? Date {
                candidates.append((dir, tPath, mtime))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

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

    private func updateConversationChoices(candidates: [(id: String, path: String, mtime: Date)]) {
        var choices: [ConversationChoice] = []
        for item in candidates.prefix(8) {
            let title = cachedTitles[item.id] ?? extractTitleFromTranscriptHead(path: item.path) ?? String(item.id.prefix(8))
            choices.append(ConversationChoice(
                id: item.id,
                title: title,
                updatedAt: item.mtime,
                transcriptPath: item.path,
                modelId: nil
            ))
        }
        state.recentConversations = choices
    }

    private func extractTitleFromTranscriptHead(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
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
                let truncated = cleaned.count > 34 ? String(cleaned.prefix(34)) + "…" : cleaned
                return truncated
            }
        }
        return nil
    }

    private func resolveTargetTranscript() -> (path: String, conversationId: String) {
        let fm = FileManager.default

        if let pinned = state.pinnedConversationId, !pinned.isEmpty {
            let pinnedPath = AppPaths.brainDir
                .appendingPathComponent(pinned)
                .appendingPathComponent(".system_generated/logs/transcript.jsonl").path
            if fm.fileExists(atPath: pinnedPath) {
                return (pinnedPath, pinned)
            }
        }

        // Prefer hook-reported transcript if hook fired within last 2 minutes
        if !hookActiveTranscriptPath.isEmpty,
           Date().timeIntervalSince(hookLastEventAt) < 120,
           fm.fileExists(atPath: hookActiveTranscriptPath) {
            let conv = hookActiveConvId.isEmpty ? conversationId(fromPath: hookActiveTranscriptPath) : hookActiveConvId
            return (hookActiveTranscriptPath, conv)
        }

        if let newest = state.recentConversations.first {
            return (newest.transcriptPath, newest.id)
        }

        return ("", "")
    }

    private func conversationId(fromPath path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        if let brainIdx = components.firstIndex(of: "brain"), brainIdx + 1 < components.count {
            return components[brainIdx + 1]
        }
        return ""
    }

    private func switchToTranscript(path: String, conversationId: String) {
        stopVnodeWatch()
        activePath = path
        activeConversationId = conversationId
        activeInode = 0
        readOffset = 0
        lineRemainder = ""
        parsedSteps = []

        state.conversationId = conversationId
        if !conversationId.isEmpty {
            if let cached = cachedTitles[conversationId] {
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
        vnodeFd = fd

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
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.vnodeFd >= 0 {
                close(self.vnodeFd)
                self.vnodeFd = -1
            }
        }
        vnodeSource = source
        source.resume()
    }

    private func stopVnodeWatch() {
        vnodeSource?.cancel()
        vnodeSource = nil
        if vnodeFd >= 0 {
            close(vnodeFd)
            vnodeFd = -1
        }
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
            textPreview: nil,
            observedDoneMs: obsMs
        )
    }

    private func recomputeMetrics() {
        let planners = parsedSteps.filter { $0.type == "PLANNER_RESPONSE" }
        let latestPlanner = planners.last

        let resolvedModelId: String
        if let m = latestPlanner?.model, !m.isEmpty {
            resolvedModelId = m
        } else if activeConversationId == hookActiveConvId, !hookActiveModel.isEmpty {
            resolvedModelId = hookActiveModel
        } else {
            resolvedModelId = ""
        }

        let modelChanged = (resolvedModelId != state.modelId)
        state.modelId = resolvedModelId
        let spec = ModelCatalog.spec(for: resolvedModelId, observedThresholds: observedThresholds)
        state.modelDisplayName = spec.displayName
        state.contextWindow = spec.contextWindow
        state.compactionThreshold = spec.defaultThreshold
        state.thresholdSource = observedThresholds[spec.familyKey] != nil ? "calibrated" : "default"

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

            // Priority 1: Live hook timing paired with live VNODE observation or Stop hook
            if let matchingHook = hookTimings.last(where: {
                ($0.initialNumSteps ?? Int.max) <= step.stepIndex && $0.preInvocationMs != nil
            }), let preMs = matchingHook.preInvocationMs {
                if let obsMs = step.observedDoneMs, obsMs > preMs {
                    dt = (obsMs - preMs) / 1000.0
                } else if idx == parsedSteps.count - 1,
                          let stopMs = matchingHook.stopMs,
                          stopMs > preMs {
                    dt = (stopMs - preMs) / 1000.0
                }
            }

            // Priority 2: Transcript timestamp delta to immediate next step
            if dt == nil, idx + 1 < parsedSteps.count,
               let start = step.createdAt,
               let end = parsedSteps[idx + 1].createdAt {
                let diff = end.timeIntervalSince(start)
                if diff >= 0.8 && diff <= 300.0 {
                    dt = diff
                }
            }

            if let duration = dt, duration >= 0.4 {
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

        // Fallback idle check if generating flag lingered without Stop hook
        if state.isGenerating,
           let started = state.generatingStartedAt,
           Date().timeIntervalSince(started) > 180 {
            state.isGenerating = false
            state.generatingStartedAt = nil
        }
    }
}
