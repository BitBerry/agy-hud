import Foundation
import Combine

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var dataDir: URL {
        home.appendingPathComponent(".gemini/antigravity/plugin_data/agy-hud", isDirectory: true)
    }

    static var brainDir: URL {
        home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    static var socketURL: URL {
        dataDir.appendingPathComponent("hud.sock")
    }

    static var runtimeStateURL: URL {
        dataDir.appendingPathComponent("runtime-state.json")
    }

    static var quotaURL: URL {
        dataDir.appendingPathComponent("quota.json")
    }

    static var prefsURL: URL {
        dataDir.appendingPathComponent("prefs.json")
    }

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(
            at: dataDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func writeAtomic0600(_ data: Data, to url: URL) {
        ensureDataDir()
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

struct UserPrefs: Codable, Equatable {
    var autoLaunch: Bool = true
    var alwaysOnTop: Bool = false
    var miniPill: Bool = false
    var pinnedConversationId: String? = nil
    var customOffsetX: Double? = nil
    var customOffsetY: Double? = nil

    static func load() -> UserPrefs {
        guard let data = try? Data(contentsOf: AppPaths.prefsURL),
              let decoded = try? JSONDecoder().decode(UserPrefs.self, from: data) else {
            return UserPrefs()
        }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            AppPaths.writeAtomic0600(data, to: AppPaths.prefsURL)
        }
    }
}

struct HookIPCMessage: Codable {
    let event: String
    let tsMs: Double
    let conversationId: String?
    let transcriptPath: String?
    let modelName: String?
    let invocationNum: Int?
    let initialNumSteps: Int?
    let terminationReason: String?
    let lsAddress: String?
    let csrfToken: String?
}

struct HookTimingRecord: Codable, Equatable {
    var invocationNum: Int?
    var initialNumSteps: Int?
    var preInvocationMs: Double?
    var postInvocationMs: Double?
    var stopMs: Double?
    var modelName: String?
}

struct RuntimeStateFile: Codable {
    var activeConversationId: String?
    var activeTranscriptPath: String?
    var activeModelName: String?
    var lastEvent: String?
    var lastEventMs: Double?
    var isGenerating: Bool?
    var lsAddress: String?
    var timings: [String: [HookTimingRecord]]?
}

struct CompactionRecord: Identifiable, Equatable {
    let stepIndex: Int
    let preTokens: Int
    let postTokens: Int?
    let summaryTokens: Int
    let timestamp: Date?

    var id: Int { stepIndex }

    var savedTokens: Int? {
        guard let post = postTokens else { return nil }
        return max(0, preTokens - post)
    }

    var savedRatio: Double? {
        guard let saved = savedTokens, preTokens > 0 else { return nil }
        return Double(saved) / Double(preTokens)
    }
}

struct ConversationChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Date
    let transcriptPath: String
    let modelId: String?
}

struct QuotaCreditInfo: Codable, Equatable {
    let creditType: String
    let minimumCreditAmountForUsage: String
}

struct QuotaPlanStatus: Codable, Equatable {
    let availablePromptCredits: Int?
    let availableFlowCredits: Int?
}

struct QuotaModelRaw: Codable, Equatable {
    let label: String
    let modelId: String
    let remainingFraction: Double?
    let resetTime: String?
    let tagTitle: String?
}

struct QuotaBucketRaw: Codable, Equatable {
    let bucketId: String
    let displayName: String
    let window: String
    let remainingFraction: Double
    let resetTime: String?
    let description: String?
}

struct QuotaSummaryGroupRaw: Codable, Equatable {
    let displayName: String
    let description: String?
    let buckets: [QuotaBucketRaw]
}

struct QuotaFileSnapshot: Codable, Equatable {
    let updatedAtMs: Double
    let tierName: String
    let availableCredits: [QuotaCreditInfo]
    let planStatus: QuotaPlanStatus?
    let summaryGroups: [QuotaSummaryGroupRaw]?
    let models: [QuotaModelRaw]
}

struct QuotaBucketView: Identifiable, Equatable {
    let id: String
    let window: String
    let shortLabel: String
    let remainingFraction: Double
    let resetTime: String?
    let description: String?
}

struct QuotaGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let buckets: [QuotaBucketView]
    let isActiveGroup: Bool

    var fiveHourBucket: QuotaBucketView? {
        buckets.first { $0.window == "5h" }
    }

    var weeklyBucket: QuotaBucketView? {
        buckets.first { $0.window == "weekly" }
    }

    var headlineFraction: Double {
        if let minFrac = buckets.map(\.remainingFraction).min() {
            return minFrac
        }
        return fiveHourBucket?.remainingFraction ?? buckets.first?.remainingFraction ?? 1.0
    }
}

struct QuotaViewData: Equatable {
    let updatedAt: Date
    let tierName: String
    let availableCredits: [QuotaCreditInfo]
    let planStatus: QuotaPlanStatus?
    let groups: [QuotaGroup]

    var activeGroup: QuotaGroup? {
        groups.first(where: { $0.isActiveGroup }) ?? groups.first
    }
}

struct ModelSpec {
    let familyKey: String
    let displayName: String
    let contextWindow: Int
    let defaultThreshold: Int
}

enum ModelCatalog {
    static func familyKey(for modelId: String) -> String {
        let lower = modelId.lowercased()
        if lower.hasPrefix("gemini-4-neon") { return "gemini-4-neon" }
        if lower.hasPrefix("gemini-4-carbon") { return "gemini-4-carbon" }
        if lower.hasPrefix("gemini-4-argon") { return "gemini-4-argon" }
        if lower.hasPrefix("gemini-4-hydrogen-tiered") { return "gemini-4-hydrogen-tiered" }
        if lower.hasPrefix("gemini-4-hydrogen") { return "gemini-4-hydrogen" }
        if lower.hasPrefix("gemini-pro-orchestrator") { return "gemini-pro-orchestrator" }
        if lower.hasPrefix("gemini-3") || lower.hasPrefix("gemini-flash") { return "gemini-flash" }
        if lower.hasPrefix("claude-opus-5-5") { return "claude-opus-5-5" }
        if lower.hasPrefix("claude-sonnet-5-5") { return "claude-sonnet-5-5" }
        if lower.hasPrefix("claude-") { return "claude" }
        if lower.hasPrefix("gpt-oss-120b") { return "gpt-oss-120b" }
        return lower.isEmpty ? "unknown" : lower
    }

    static func spec(for modelId: String, observedThresholds: [String: Int]) -> ModelSpec {
        let lower = modelId.lowercased()
        let key = familyKey(for: lower)

        let baseName: String
        let window: Int
        let fallbackThreshold: Int

        switch key {
        case "gemini-4-neon":
            baseName = "Gemini 4 Neon"
            window = 1_000_000
            fallbackThreshold = 512_000
        case "gemini-4-carbon":
            baseName = "Gemini 4 Carbon"
            window = 1_000_000
            fallbackThreshold = 512_000
        case "gemini-4-argon":
            baseName = "Gemini 4 Argon"
            window = 1_000_000
            fallbackThreshold = 512_000
        case "gemini-4-hydrogen-tiered":
            baseName = "Gemini 4 Hydrogen"
            window = 256_000
            fallbackThreshold = 200_000
        case "gemini-4-hydrogen":
            baseName = "Gemini 4 Hydrogen"
            window = 1_000_000
            fallbackThreshold = 512_000
        case "gemini-pro-orchestrator":
            if lower.contains("neon") {
                baseName = "Orchestrator · Neon"
            } else if lower.contains("argon") {
                baseName = "Orchestrator · Argon"
            } else {
                baseName = "Orchestrator"
            }
            window = 1_000_000
            fallbackThreshold = 512_000
        case "gemini-flash":
            baseName = lower.contains("3.8") ? "Gemini 3.8 Flash" : "Gemini Flash"
            window = 1_000_000
            fallbackThreshold = 512_000
        case "claude-opus-5-5":
            baseName = "Claude Opus 5.5"
            window = 200_000
            fallbackThreshold = 160_000
        case "claude-sonnet-5-5":
            baseName = "Claude Sonnet 5.5"
            window = 200_000
            fallbackThreshold = 160_000
        case "claude":
            baseName = "Claude"
            window = 200_000
            fallbackThreshold = 160_000
        case "gpt-oss-120b":
            baseName = "GPT-OSS 120B"
            window = 128_000
            fallbackThreshold = 100_000
        default:
            baseName = prettifyModelName(modelId)
            window = 1_000_000
            fallbackThreshold = 512_000
        }

        let effortSuffix: String
        if key == "gemini-pro-orchestrator" || lower.isEmpty {
            effortSuffix = ""
        } else if lower.hasSuffix("-xhigh") {
            effortSuffix = " · XHigh"
        } else if lower.hasSuffix("-high") {
            effortSuffix = " · High"
        } else if lower.hasSuffix("-medium") {
            effortSuffix = " · Med"
        } else if lower.hasSuffix("-low") {
            effortSuffix = " · Low"
        } else {
            effortSuffix = ""
        }

        let threshold = observedThresholds[key] ?? fallbackThreshold
        return ModelSpec(
            familyKey: key,
            displayName: "\(baseName)\(effortSuffix)",
            contextWindow: window,
            defaultThreshold: threshold
        )
    }

    private static func prettifyModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Waiting..." }
        return trimmed
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum HUDFormatters {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return isoWithFractional.date(from: value) ?? isoBasic.date(from: value)
    }

    static func formatTokens(_ count: Int) -> String {
        let absVal = abs(count)
        let sign = count < 0 ? "-" : ""
        if absVal >= 1_000_000 {
            let m = Double(absVal) / 1_000_000.0
            return String(format: "%@%.2fM", sign, m)
        } else if absVal >= 1_000 {
            let k = Double(absVal) / 1_000.0
            if k >= 100 {
                return String(format: "%@%.0fK", sign, k)
            }
            return String(format: "%@%.1fK", sign, k)
        }
        return "\(count)"
    }

    static func formatSignedTokens(_ delta: Int) -> String {
        if delta > 0 { return "+\(formatTokens(delta))" }
        if delta < 0 { return formatTokens(delta) }
        return "0"
    }

    static func formatTps(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "--" }
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--" }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m\(secs)s"
    }

    static func formatQuotaPercent(_ fraction: Double) -> String {
        let clamped = max(0.0, min(1.0, fraction))
        if clamped >= 0.9995 { return "100%" }
        if clamped <= 0.0005 { return "0%" }
        let pct = clamped * 100.0
        if abs(pct - pct.rounded()) < 0.05 {
            return String(format: "%.0f%%", pct.rounded())
        }
        return String(format: "%.1f%%", pct)
    }

    static func formatCountdown(_ iso: String?, now: Date = Date()) -> String {
        guard let target = parseISO(iso) else { return "--" }
        let diff = Int(target.timeIntervalSince(now))
        if diff <= 0 { return "已重置" }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(max(1, mins))m"
    }

    static func formatClock(_ iso: String?) -> String {
        guard let target = parseISO(iso) else { return "" }
        return clockFormatter.string(from: target)
    }

    static func formatRelative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let sec = max(0, Int(now.timeIntervalSince(date)))
        if sec < 5 { return "刚刚" }
        if sec < 60 { return "\(sec)s前" }
        let min = sec / 60
        if min < 60 { return "\(min)m前" }
        return "\(min / 60)h前"
    }
}

@MainActor
final class HUDState: ObservableObject {
    @Published var conversationId: String = ""
    @Published var conversationTitle: String = "等待对话..."
    @Published var recentConversations: [ConversationChoice] = []

    @Published var isGenerating: Bool = false
    @Published var generatingStartedAt: Date? = nil
    @Published var modelId: String = ""
    @Published var modelDisplayName: String = "Waiting..."

    @Published var contextTokens: Int = 0
    @Published var cacheReadTokens: Int = 0
    @Published var freshInputTokens: Int = 0
    @Published var lastOutputTokens: Int = 0
    @Published var contextDelta: Int = 0
    @Published var contextWindow: Int = 1_000_000
    @Published var cacheHitRate: Double = 0

    @Published var lastTurnTps: Double? = nil
    @Published var avgTps: Double? = nil
    @Published var peakTps: Double? = nil
    @Published var lastTurnTokens: Int = 0
    @Published var lastTurnDurationSec: Double? = nil
    @Published var recentTps: [Double] = []

    @Published var compactionThreshold: Int = 512_000
    @Published var thresholdSource: String = "default"
    @Published var compactionCount: Int = 0
    @Published var lastCompaction: CompactionRecord? = nil
    @Published var allCompactions: [CompactionRecord] = []

    @Published var quota: QuotaViewData? = nil
    @Published var isQuotaLoading: Bool = false
    @Published var quotaError: String? = nil
    @Published var isQuotaExpanded: Bool = false

    @Published var isVisible: Bool = false
    @Published var userHidden: Bool = false
    @Published var isMiniPill: Bool
    @Published var alwaysOnTop: Bool
    @Published var autoLaunch: Bool
    @Published var pinnedConversationId: String?

    @Published var prefs: UserPrefs

    init() {
        let loaded = UserPrefs.load()
        self.prefs = loaded
        self.isMiniPill = loaded.miniPill
        self.alwaysOnTop = loaded.alwaysOnTop
        self.autoLaunch = loaded.autoLaunch
        self.pinnedConversationId = loaded.pinnedConversationId
    }

    func updatePrefs(_ mutate: (inout UserPrefs) -> Void) {
        mutate(&prefs)
        isMiniPill = prefs.miniPill
        alwaysOnTop = prefs.alwaysOnTop
        autoLaunch = prefs.autoLaunch
        pinnedConversationId = prefs.pinnedConversationId
        prefs.save()
    }
}
