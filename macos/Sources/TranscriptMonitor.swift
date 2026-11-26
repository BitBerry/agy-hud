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

    private struct AnnotationEntry {
        let conversationId: String
        let mtime: Date
        let title: String?
        let lastUserViewTime: Double?
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
    private var annotationsDirSource: DispatchSourceFileSystemObject?
    private var annotationsDirFd: Int32 = -1
    private var pollTimer: Timer?
    private var lastConversationScanAt: Date = .distantPast
    private var lastTitleFetchAt: Date = .distantPast
    private var cachedTitles: [String: String] = [:]
    private var annotationCache: [String: AnnotationEntry] = [:]
    private var lastHandledViewTime: Double = 0
    private var currentAutoViewedId: String = ""

    private var observedThresholds: [String: Int] = [:]
    private var hookTimingsByConv: [String: [HookTimingRecord]] = [:]
    private var generatingStartByConv: [String: Date] = [:]
    private var hookActiveConvId: String = ""
    private var hookActiveModel: String = ""
    private var hookLastEventAt: Date = .distantPast

    init(state: HUDState, quotaClient: QuotaClient) {
        self.state = state
        self.quotaClient = quotaClient
        loadRuntimeStateSeed()
        calibrateCompactionThresholdsAsync()
        startAnnotationsDirWatch()
        refreshNow(scanConversations: true)
    }

    func start() {
        startAnnotationsDirWatch()
        scheduleTimer()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
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
        refreshNow(scanConversations: true)
    }

    func handleHookEvent(_ msg: HookIPCMessage) {
        let convId = msg.conversationId ?? ""
        let eventDate = Date(timeIntervalSince1970: msg.tsMs / 1000.0)
        if !convId.isEmpty {
            hookActiveConvId = convId
        }
        if let model = msg.modelName, !model.isEmpty {
            hookActiveModel = model
        }
        if msg.event == "SessionStart" || msg.event == "PreInvocation" {
            hookLastEventAt = eventDate
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
        if target.conversationId != activeConversationId || target.path != activePath {
            switchToTranscript(path: target.path, conversationId: target.conversationId)
        } else if !activePath.isEmpty {
            readAppendedBytes(liveArrivalMs: now.timeIntervalSince1970 * 1000.0)
        }

        recomputeMetrics()
    }

    // MARK: - Annotations (`last_user_view_time`) Tracking

    private func startAnnotationsDirWatch() {
        guard annotationsDirSource == nil else { return }
        let dirPath = AppPaths.annotationsDir.path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        annotationsDirFd = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.refreshNow(scanConversations: false)
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.annotationsDirFd >= 0 {
                close(self.annotationsDirFd)
                self.annotationsDirFd = -1
            }
        }
        annotationsDirSource = source
        source.resume()
    }

    private func stopAnnotationsDirWatch() {
        annotationsDirSource?.cancel()
        annotationsDirSource = nil
        if annotationsDirFd >= 0 {
            close(annotationsDirFd)
            annotationsDirFd = -1
        }
    }

    private func scanAnnotationsFast() {
        let fm = FileManager.default
        let dirPath = AppPaths.annotationsDir.path
        guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

        var liveIds = Set<String>()
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

        for oldKey in annotationCache.keys where !liveIds.contains(oldKey) {
            annotationCache.removeValue(forKey: oldKey)
        }
    }

    private func resolveMostRecentlyViewedConversation() -> (id: String, viewTime: Double)? {
        guard let maxVt = annotationCache.values.compactMap(\.lastUserViewTime).max() else {
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
        let tied = annotationCache.values.filter { entry in
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
        if let model = runtime.activeModelName, !model.isEmpty {
            hookActiveModel = model
        }
        if let ms = runtime.lastEventMs {
            hookLastEventAt = Date(timeIntervalSince1970: ms / 1000.0)
        }
        if runtime.isGenerating == true,
           !hookActiveConvId.isEmpty,
           Date().timeIntervalSince(hookLastEventAt) < 120 {
            generatingStartByConv[hookActiveConvId] = hookLastEventAt
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

        var candidates: [(id: String, path: String, sortTime: Date)] = []
        for dir in dirs {
            let tPath = "\(brainPath)/\(dir)/.system_generated/logs/transcript.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: tPath),
                  let mtime = attrs[.modificationDate] as? Date else {
                continue
            }
            let viewDate = annotationCache[dir]?.lastUserViewTime.map { Date(timeIntervalSince1970: $0) }
            let sortTime = viewDate.map { max($0, mtime) } ?? mtime
            candidates.append((dir, tPath, sortTime))
        }
        candidates.sort { $0.sortTime > $1.sortTime }

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

    private func updateConversationChoices(candidates: [(id: String, path: String, sortTime: Date)]) {
        var choices: [ConversationChoice] = []
        for item in candidates.prefix(8) {
            let title = cachedTitles[item.id]
                ?? annotationCache[item.id]?.title
                ?? extractTitleFromTranscriptHead(path: item.path)
                ?? String(item.id.prefix(8))
            choices.append(ConversationChoice(
                id: item.id,
                title: title,
                updatedAt: item.sortTime,
                transcriptPath: item.path,
                modelId: nil
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
        let compact = AppPaths.brainDir
            .appendingPathComponent(conversationId)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl").path
        if FileManager.default.fileExists(atPath: compact) {
            return compact
        }
        let full = AppPaths.brainDir
            .appendingPathComponent(conversationId)
            .appendingPathComponent(".system_generated/logs/transcript_full.jsonl").path
        if FileManager.default.fileExists(atPath: full) {
            return full
        }
        return ""
    }

    private func resolveTargetTranscript() -> (path: String, conversationId: String) {
        // 1. User manually pinned a specific conversation in the Menu Bar
        if let pinned = state.pinnedConversationId, !pinned.isEmpty {
            return (transcriptPath(for: pinned), pinned)
        }

        // 2. Primary source: Antigravity's `annotations/<id>.pbtxt` `last_user_view_time`
        if let viewed = resolveMostRecentlyViewedConversation() {
            // Only prefer a brand-new hook conversation if it has no annotation view time yet
            // AND started strictly after the last viewed conversation.
            if !hookActiveConvId.isEmpty,
               hookActiveConvId != viewed.id,
               annotationCache[hookActiveConvId]?.lastUserViewTime == nil,
               hookLastEventAt.timeIntervalSince1970 > viewed.viewTime {
                return (transcriptPath(for: hookActiveConvId), hookActiveConvId)
            }
            return (transcriptPath(for: viewed.id), viewed.id)
        }

        // 3. Fallback when no annotation files exist yet
        if !hookActiveConvId.isEmpty {
            return (transcriptPath(for: hookActiveConvId), hookActiveConvId)
        }
        if let newest = state.recentConversations.first {
            return (newest.transcriptPath, newest.id)
        }
        return ("", "")
    }

    // MARK: - Transcript Reading & VNODE Watch

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
            if Date().timeIntervalSince(started) > 180 {
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
}
