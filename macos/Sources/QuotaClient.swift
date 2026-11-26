import Foundation

@MainActor
final class QuotaClient {
    private let state: HUDState
    private var lsAddress: String?
    private var csrfToken: String?
    private var lastFetchAt: Date?
    private var lastFileMtime: Date?
    private var lastSnapshot: QuotaFileSnapshot?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 5.0
        return URLSession(configuration: cfg)
    }()

    init(state: HUDState) {
        self.state = state
        loadFromDiskIfNewer(force: true)
    }

    func updateCredentials(lsAddress: String?, csrfToken: String?) {
        if let lsAddress, !lsAddress.isEmpty {
            self.lsAddress = lsAddress
        }
        if let csrfToken, !csrfToken.isEmpty {
            self.csrfToken = csrfToken
        }
    }

    var hasLiveCredentials: Bool {
        guard let lsAddress, !lsAddress.isEmpty,
              let csrfToken, !csrfToken.isEmpty else {
            return false
        }
        return true
    }

    func loadFromDiskIfNewer(force: Bool = false) {
        let url = AppPaths.quotaURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return
        }
        if !force, let prev = lastFileMtime, abs(mtime.timeIntervalSince(prev)) < 0.05 {
            return
        }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(QuotaFileSnapshot.self, from: data) else {
            return
        }
        lastFileMtime = mtime
        lastSnapshot = snapshot
        publishSnapshot(snapshot)
    }

    func regroupForActiveModel() {
        if let snap = lastSnapshot {
            publishSnapshot(snap)
        }
    }

    func refresh(force: Bool) {
        loadFromDiskIfNewer()

        guard let lsAddress, !lsAddress.isEmpty,
              let csrfToken, !csrfToken.isEmpty else {
            if state.quota == nil && state.quotaError == nil {
                state.quotaError = "等待首次对话同步"
            }
            return
        }

        if !force, let last = lastFetchAt, Date().timeIntervalSince(last) < 25.0 {
            return
        }

        if state.isQuotaLoading { return }
        state.isQuotaLoading = true
        state.quotaError = nil

        let summaryReq = makeLSRequest(
            lsAddress: lsAddress,
            csrfToken: csrfToken,
            method: "RetrieveUserQuotaSummary",
            body: [:]
        )
        let statusReq = makeLSRequest(
            lsAddress: lsAddress,
            csrfToken: csrfToken,
            method: "GetUserStatus",
            body: [
                "metadata": [
                    "ideName": "antigravity",
                    "extensionName": "antigravity",
                    "locale": "en",
                ]
            ]
        )

        guard let summaryReq, let statusReq else {
            state.isQuotaLoading = false
            state.quotaError = "无效 LS 地址"
            return
        }

        let group = DispatchGroup()
        var summaryData: Data?
        var statusData: Data?
        var summaryError: Error?

        group.enter()
        session.dataTask(with: summaryReq) { data, response, error in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                summaryData = data
            } else {
                summaryError = error
            }
            group.leave()
        }.resume()

        group.enter()
        session.dataTask(with: statusReq) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                statusData = data
            }
            group.leave()
        }.resume()

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.state.isQuotaLoading = false

            let parsedGroups = summaryData.flatMap { Self.parseQuotaSummaryJSON($0) }
            let parsedStatus = statusData.flatMap { Self.parseUserStatusJSON($0) }

            if parsedGroups == nil && parsedStatus == nil {
                if let err = summaryError {
                    self.state.quotaError = "刷新失败: \(err.localizedDescription)"
                } else {
                    self.state.quotaError = "配额响应解析失败"
                }
                return
            }

            let snapshot = QuotaFileSnapshot(
                updatedAtMs: Date().timeIntervalSince1970 * 1000.0,
                tierName: parsedStatus?.tierName ?? self.lastSnapshot?.tierName ?? "Antigravity",
                availableCredits: parsedStatus?.availableCredits ?? self.lastSnapshot?.availableCredits ?? [],
                planStatus: parsedStatus?.planStatus ?? self.lastSnapshot?.planStatus,
                summaryGroups: parsedGroups ?? self.lastSnapshot?.summaryGroups,
                models: parsedStatus?.models ?? self.lastSnapshot?.models ?? []
            )

            self.lastFetchAt = Date()
            self.lastSnapshot = snapshot
            self.publishSnapshot(snapshot)
            Self.saveSanitizedSnapshot(snapshot)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: AppPaths.quotaURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                self.lastFileMtime = mtime
            }
        }
    }

    func fetchConversationTitles(completion: @escaping ([String: String]) -> Void) {
        guard let lsAddress, !lsAddress.isEmpty,
              let csrfToken, !csrfToken.isEmpty,
              let url = URL(string: "http://\(lsAddress)/product.v1.ConversationService/ListConversations") else {
            completion([:])
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(csrfToken, forHTTPHeaderField: "x-antigravity-csrf-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pageSize": 20])

        session.dataTask(with: req) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let convs = root["conversations"] as? [[String: Any]] else {
                Task { @MainActor in completion([:]) }
                return
            }

            var titles: [String: String] = [:]
            for conv in convs {
                guard let id = conv["id"] as? String else { continue }
                let ann = conv["annotations"] as? [String: Any]
                let st = conv["state"] as? [String: Any]
                let t = (ann?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let s = (st?["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let t, !t.isEmpty {
                    titles[id] = t
                } else if let s, !s.isEmpty {
                    titles[id] = s
                }
            }
            Task { @MainActor in completion(titles) }
        }.resume()
    }

    private func makeLSRequest(
        lsAddress: String,
        csrfToken: String,
        method: String,
        body: [String: Any]
    ) -> URLRequest? {
        guard let url = URL(string: "http://\(lsAddress)/exa.language_server_pb.LanguageServerService/\(method)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func publishSnapshot(_ snapshot: QuotaFileSnapshot) {
        let groups = Self.buildGroups(from: snapshot, activeModelId: state.modelId)
        state.quota = QuotaViewData(
            updatedAt: Date(timeIntervalSince1970: snapshot.updatedAtMs / 1000.0),
            tierName: snapshot.tierName,
            availableCredits: snapshot.availableCredits,
            planStatus: snapshot.planStatus,
            groups: groups
        )
        state.quotaError = nil
    }

    private static func saveSanitizedSnapshot(_ snapshot: QuotaFileSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(snapshot) {
            AppPaths.writeAtomic0600(data, to: AppPaths.quotaURL)
        }
    }

    private static func parseQuotaSummaryJSON(_ data: Data) -> [QuotaSummaryGroupRaw]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseObj = root["response"] as? [String: Any],
              let rawGroups = responseObj["groups"] as? [[String: Any]] else {
            return nil
        }

        return rawGroups.map { grp in
            let rawBuckets = grp["buckets"] as? [[String: Any]] ?? []
            let buckets = rawBuckets.map { b in
                QuotaBucketRaw(
                    bucketId: (b["bucketId"] as? String) ?? "",
                    displayName: (b["displayName"] as? String) ?? "",
                    window: (b["window"] as? String) ?? "",
                    remainingFraction: (b["remainingFraction"] as? Double) ?? 1.0,
                    resetTime: b["resetTime"] as? String,
                    description: b["description"] as? String
                )
            }
            return QuotaSummaryGroupRaw(
                displayName: (grp["displayName"] as? String) ?? "",
                description: grp["description"] as? String,
                buckets: buckets
            )
        }
    }

    private struct ParsedUserStatus {
        let tierName: String
        let availableCredits: [QuotaCreditInfo]
        let planStatus: QuotaPlanStatus?
        let models: [QuotaModelRaw]
    }

    private static func parseUserStatusJSON(_ data: Data) -> ParsedUserStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userStatus = root["userStatus"] as? [String: Any] else {
            return nil
        }

        let userTier = userStatus["userTier"] as? [String: Any]
        let planStatusDict = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatusDict?["planInfo"] as? [String: Any]
        let tierName = (userTier?["name"] as? String)
            ?? (planInfo?["planName"] as? String)
            ?? "Unknown"

        let rawCredits = userTier?["availableCredits"] as? [[String: Any]] ?? []
        let credits = rawCredits.map { item in
            QuotaCreditInfo(
                creditType: (item["creditType"] as? String) ?? "",
                minimumCreditAmountForUsage: (item["minimumCreditAmountForUsage"] as? String) ?? ""
            )
        }

        let planStatus: QuotaPlanStatus? = planStatusDict.map { ps in
            QuotaPlanStatus(
                availablePromptCredits: ps["availablePromptCredits"] as? Int,
                availableFlowCredits: ps["availableFlowCredits"] as? Int
            )
        }

        let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any]
        let rawConfigs = cascadeData?["clientModelConfigs"] as? [[String: Any]] ?? []
        let models = rawConfigs.map { cfg -> QuotaModelRaw in
            let quotaInfo = cfg["quotaInfo"] as? [String: Any]
            return QuotaModelRaw(
                label: (cfg["label"] as? String) ?? "",
                modelId: (cfg["modelId"] as? String) ?? "",
                remainingFraction: quotaInfo?["remainingFraction"] as? Double,
                resetTime: quotaInfo?["resetTime"] as? String,
                tagTitle: cfg["tagTitle"] as? String
            )
        }

        return ParsedUserStatus(
            tierName: tierName,
            availableCredits: credits,
            planStatus: planStatus,
            models: models
        )
    }

    static func buildGroups(from snapshot: QuotaFileSnapshot, activeModelId: String) -> [QuotaGroup] {
        let activeLower = activeModelId.lowercased()

        if let summaryGroups = snapshot.summaryGroups, !summaryGroups.isEmpty {
            return summaryGroups.enumerated().map { idx, grp in
                let nameLower = grp.displayName.lowercased()
                let descLower = (grp.description ?? "").lowercased()
                let isActive: Bool
                if activeLower.isEmpty {
                    isActive = (idx == 0)
                } else if activeLower.contains("gemini") || activeLower.contains("orchestrator") {
                    isActive = nameLower.contains("gemini") || descLower.contains("gemini")
                } else if activeLower.contains("claude") {
                    isActive = nameLower.contains("claude") || descLower.contains("claude")
                } else if activeLower.contains("gpt") {
                    isActive = nameLower.contains("gpt") || descLower.contains("gpt")
                } else {
                    isActive = false
                }

                let buckets = grp.buckets.enumerated().map { bIdx, b in
                    let shortLabel: String
                    if b.window == "weekly" {
                        shortLabel = "Weekly limit"
                    } else if b.window == "5h" {
                        shortLabel = "5h limit"
                    } else {
                        shortLabel = b.displayName.isEmpty ? b.window : b.displayName
                    }
                    let bid = b.bucketId.isEmpty ? "\(idx)-\(bIdx)-\(b.window)" : b.bucketId
                    return QuotaBucketView(
                        id: bid,
                        window: b.window,
                        shortLabel: shortLabel,
                        remainingFraction: max(0.0, min(1.0, b.remainingFraction)),
                        resetTime: b.resetTime,
                        description: b.description
                    )
                }

                return QuotaGroup(
                    id: "\(idx)-\(grp.displayName)",
                    name: grp.displayName,
                    detail: grp.description ?? "",
                    buckets: buckets,
                    isActiveGroup: isActive
                )
            }
        }

        // Backward-compatible fallback if only GetUserStatus models exist
        return fallbackGroupModels(snapshot.models, activeModelId: activeModelId)
    }

    private static func fallbackGroupModels(_ models: [QuotaModelRaw], activeModelId: String) -> [QuotaGroup] {
        struct FamilyBucket {
            let familyName: String
            let order: Int
            var remainingFraction: Double
            var resetTime: String?
            var hasActiveModel: Bool
        }

        let activeLower = activeModelId.lowercased()
        var byFamily: [String: FamilyBucket] = [:]

        for model in models {
            guard let frac = model.remainingFraction else { continue }
            let idLower = model.modelId.lowercased()
            let (familyName, order): (String, Int)
            if idLower.hasPrefix("gemini-") {
                (familyName, order) = ("Gemini Models", 0)
            } else if idLower.hasPrefix("claude-") || idLower.hasPrefix("gpt-") {
                (familyName, order) = ("Claude and GPT models", 1)
            } else {
                (familyName, order) = (model.label.isEmpty ? model.modelId : model.label, 2)
            }

            let isActive = !activeLower.isEmpty && (
                idLower == activeLower ||
                ((activeLower.contains("gemini") || activeLower.contains("orchestrator")) && familyName == "Gemini Models") ||
                ((activeLower.contains("claude") || activeLower.contains("gpt")) && familyName == "Claude and GPT models")
            )

            if var existing = byFamily[familyName] {
                existing.remainingFraction = min(existing.remainingFraction, frac)
                if existing.resetTime == nil { existing.resetTime = model.resetTime }
                existing.hasActiveModel = existing.hasActiveModel || isActive
                byFamily[familyName] = existing
            } else {
                byFamily[familyName] = FamilyBucket(
                    familyName: familyName,
                    order: order,
                    remainingFraction: frac,
                    resetTime: model.resetTime,
                    hasActiveModel: isActive
                )
            }
        }

        return byFamily.values
            .sorted { $0.order < $1.order }
            .map { bucket in
                QuotaGroup(
                    id: bucket.familyName,
                    name: bucket.familyName,
                    detail: "",
                    buckets: [
                        QuotaBucketView(
                            id: "\(bucket.familyName)-fallback",
                            window: "5h",
                            shortLabel: "Model quota",
                            remainingFraction: max(0.0, min(1.0, bucket.remainingFraction)),
                            resetTime: bucket.resetTime,
                            description: nil
                        )
                    ],
                    isActiveGroup: bucket.hasActiveModel
                )
            }
    }
}
