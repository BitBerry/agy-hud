import SwiftUI

private struct HUDSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 {
            value = next
        }
    }
}

/// Explicit sRGB palette bypassing macOS NSVisualEffectView vibrancy blending so
/// key telemetry numbers stay crisp and high-contrast over any desktop window.
private struct HUDPalette {
    let panelBackground: Color
    let panelBorder: Color
    let cardBackground: Color
    let cardBorder: Color
    let divider: Color
    let track: Color

    let titlePrimary: Color
    let numberHero: Color
    let numberPrimary: Color
    let label: Color
    let muted: Color

    let badgeBackground: Color
    let badgeForeground: Color
    let buttonBackground: Color
    let buttonForeground: Color

    let accentCacheText: Color
    let accentCacheBar: Color
    let accentFreshBar: Color
    let accentLiveText: Color
    let accentLiveBar: Color
    let accentMintText: Color
    let accentMintBar: Color
    let accentWarnText: Color
    let accentWarnBar: Color
    let accentDangerText: Color
    let accentDangerBar: Color
    let accentChart: Color
    let accentStar: Color

    static let dark = HUDPalette(
        panelBackground: Color(red: 0.067, green: 0.082, blue: 0.114).opacity(0.92),
        panelBorder: Color.white.opacity(0.16),
        cardBackground: Color(red: 0.114, green: 0.141, blue: 0.192).opacity(0.90),
        cardBorder: Color.white.opacity(0.09),
        divider: Color.white.opacity(0.12),
        track: Color.white.opacity(0.12),

        titlePrimary: Color(red: 0.945, green: 0.961, blue: 0.980),
        numberHero: Color.white,
        numberPrimary: Color(red: 0.910, green: 0.941, blue: 0.984),
        label: Color(red: 0.569, green: 0.624, blue: 0.710),
        muted: Color(red: 0.467, green: 0.522, blue: 0.608),

        badgeBackground: Color(red: 0.376, green: 0.647, blue: 0.980).opacity(0.18),
        badgeForeground: Color(red: 0.576, green: 0.773, blue: 0.992),
        buttonBackground: Color.white.opacity(0.10),
        buttonForeground: Color(red: 0.796, green: 0.835, blue: 0.882),

        accentCacheText: Color(red: 0.220, green: 0.741, blue: 0.973),
        accentCacheBar: Color(red: 0.220, green: 0.741, blue: 0.973),
        accentFreshBar: Color(red: 0.506, green: 0.549, blue: 0.973),
        accentLiveText: Color(red: 0.204, green: 0.827, blue: 0.600),
        accentLiveBar: Color(red: 0.204, green: 0.827, blue: 0.600),
        accentMintText: Color(red: 0.176, green: 0.831, blue: 0.749),
        accentMintBar: Color(red: 0.176, green: 0.831, blue: 0.749),
        accentWarnText: Color(red: 0.984, green: 0.749, blue: 0.141),
        accentWarnBar: Color(red: 0.984, green: 0.749, blue: 0.141),
        accentDangerText: Color(red: 0.973, green: 0.443, blue: 0.443),
        accentDangerBar: Color(red: 0.973, green: 0.443, blue: 0.443),
        accentChart: Color(red: 0.376, green: 0.647, blue: 0.980),
        accentStar: Color(red: 0.980, green: 0.800, blue: 0.082)
    )

    static let light = HUDPalette(
        panelBackground: Color(red: 0.945, green: 0.961, blue: 0.976).opacity(0.95),
        panelBorder: Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.16),
        cardBackground: Color.white.opacity(0.94),
        cardBorder: Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.09),
        divider: Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.10),
        track: Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.10),

        titlePrimary: Color(red: 0.059, green: 0.090, blue: 0.165),
        numberHero: Color(red: 0.035, green: 0.051, blue: 0.086),
        numberPrimary: Color(red: 0.098, green: 0.137, blue: 0.212),
        label: Color(red: 0.349, green: 0.408, blue: 0.494),
        muted: Color(red: 0.427, green: 0.482, blue: 0.561),

        badgeBackground: Color(red: 0.145, green: 0.388, blue: 0.922).opacity(0.12),
        badgeForeground: Color(red: 0.114, green: 0.306, blue: 0.847),
        buttonBackground: Color(red: 0.059, green: 0.090, blue: 0.165).opacity(0.07),
        buttonForeground: Color(red: 0.200, green: 0.255, blue: 0.333),

        accentCacheText: Color(red: 0.012, green: 0.412, blue: 0.631),
        accentCacheBar: Color(red: 0.008, green: 0.518, blue: 0.780),
        accentFreshBar: Color(red: 0.310, green: 0.275, blue: 0.898),
        accentLiveText: Color(red: 0.016, green: 0.471, blue: 0.341),
        accentLiveBar: Color(red: 0.020, green: 0.588, blue: 0.412),
        accentMintText: Color(red: 0.059, green: 0.463, blue: 0.431),
        accentMintBar: Color(red: 0.051, green: 0.580, blue: 0.533),
        accentWarnText: Color(red: 0.706, green: 0.325, blue: 0.035),
        accentWarnBar: Color(red: 0.851, green: 0.467, blue: 0.024),
        accentDangerText: Color(red: 0.788, green: 0.110, blue: 0.110),
        accentDangerBar: Color(red: 0.863, green: 0.149, blue: 0.149),
        accentChart: Color(red: 0.145, green: 0.388, blue: 0.922),
        accentStar: Color(red: 0.851, green: 0.467, blue: 0.024)
    )

    func quotaBarColor(_ fraction: Double) -> Color {
        if fraction > 0.5 { return accentLiveBar }
        if fraction > 0.2 { return accentWarnBar }
        return accentDangerBar
    }

    func quotaValueColor(_ fraction: Double, stale: Bool = false) -> Color {
        if fraction <= 0.2 { return accentDangerText }
        if fraction <= 0.5 { return accentWarnText }
        return stale ? numberPrimary : numberHero
    }
}

struct HUDView: View {
    @ObservedObject var state: HUDState
    let onRefreshQuota: () -> Void
    let onExpandQuota: () -> Void
    let onToggleMiniPill: () -> Void
    let onSizeChange: (CGSize) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: HUDPalette {
        switch state.theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return colorScheme == .dark ? .dark : .light
        }
    }

    var body: some View {
        let cornerRadius: CGFloat = state.isMiniPill ? 17 : 14
        let p = palette
        Group {
            if state.isMiniPill {
                miniPillBody(p)
            } else {
                fullCardBody(p)
            }
        }
        .background(p.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .circular))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .strokeBorder(p.panelBorder, lineWidth: 0.9)
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HUDSizePreferenceKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(HUDSizePreferenceKey.self) { size in
            onSizeChange(size)
        }
    }

    // MARK: - Mini Pill Mode

    private func miniPillBody(_ p: HUDPalette) -> some View {
        let threshold = max(1, state.compactionThreshold)
        let isExactThreshold = state.thresholdSource == "calibrated" || state.thresholdSource == "override"
        let thresholdPrefix = isExactThreshold ? "" : "~"
        let thresholdText = "\(thresholdPrefix)\(HUDFormatters.formatTokens(threshold))"
        let remainingTokens = max(0, threshold - state.contextTokens)
        let remainingRatio = max(0.0, min(1.0, Double(remainingTokens) / Double(threshold)))
        let remainingPct = Int((remainingRatio * 100.0).rounded())
        let remainingColor: Color = remainingRatio <= 0.10
            ? p.accentDangerText
            : (remainingRatio <= 0.25 ? p.accentWarnText : p.accentMintText)

        return HStack(spacing: 7) {
            statusIndicator(size: 7, palette: p)

            if state.activeSource == .cli {
                Image(systemName: "terminal")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(p.badgeForeground)
                    .help("正在跟踪 agy CLI 对话")
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(HUDFormatters.formatTokens(state.contextTokens))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(p.numberHero)
                Text("/\(thresholdText)/")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(p.muted)
                Text("\(remainingPct)%")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(remainingColor)
            }
            .help("当前 Context / 压缩阈值 \(thresholdText) / 剩余 \(HUDFormatters.formatTokens(remainingTokens)) (\(remainingPct)%)")

            pillDivider(p)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(HUDFormatters.formatTps(state.lastTurnTps))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.numberPrimary)
                Text("t/s")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(p.muted)
            }

            if let activeQuota = state.quota?.activeGroup {
                pillDivider(p)
                HStack(spacing: 4) {
                    Circle()
                        .fill(p.quotaBarColor(activeQuota.headlineFraction))
                        .frame(width: 5.5, height: 5.5)
                    Text(HUDFormatters.formatQuotaPercent(activeQuota.headlineFraction))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(p.quotaValueColor(activeQuota.headlineFraction))
                }
            }

            Button {
                onToggleMiniPill()
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.buttonForeground)
            }
            .buttonStyle(.plain)
            .help("展开悬浮窗")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 34)
        .fixedSize(horizontal: true, vertical: true)
    }

    private func pillDivider(_ p: HUDPalette) -> some View {
        Rectangle()
            .fill(p.divider)
            .frame(width: 1, height: 12)
    }

    // MARK: - Full Card Mode

    private func fullCardBody(_ p: HUDPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection(p)
            contextCard(p)
            tpsCard(p)
            compactionCard(p)
            quotaAccordionCard(p)
        }
        .padding(10)
        .frame(width: 272, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func headerSection(_ p: HUDPalette) -> some View {
        HStack(spacing: 6) {
            statusIndicator(size: 7.5, palette: p)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.modelDisplayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.titlePrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(state.activeSource.badge)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(p.badgeForeground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(p.badgeBackground))
                        .fixedSize()
                        .help(state.activeSource == .cli ? "正在跟踪 agy CLI 对话" : "正在跟踪 Antigravity 桌面端对话")

                    Text(state.conversationTitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(p.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            Button(action: onToggleMiniPill) {
                Image(systemName: "minus")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(p.buttonForeground)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5.5)
                            .fill(p.buttonBackground)
                    )
            }
            .buttonStyle(.plain)
            .help("折叠为迷你药丸")
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Context Length Card

    private func contextCard(_ p: HUDPalette) -> some View {
        let totalWindow = max(1, state.contextWindow)
        let totalRatio = min(1.0, Double(state.contextTokens) / Double(totalWindow))
        let cacheRatio = min(totalRatio, Double(state.cacheReadTokens) / Double(totalWindow))
        let thresholdRatio = min(1.0, Double(state.compactionThreshold) / Double(totalWindow))
        let pctText = String(format: "%.1f%%", totalRatio * 100.0)
        let pctColor: Color = totalRatio >= 0.9
            ? p.accentDangerText
            : (totalRatio > 0.7 ? p.accentWarnText : p.numberPrimary)

        return cardContainer(p) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Context 长度")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(p.label)
                        .fixedSize()
                    Spacer(minLength: 4)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(HUDFormatters.formatTokens(state.contextTokens))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(p.numberHero)
                        Text("/ \(HUDFormatters.formatTokens(totalWindow))")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(p.muted)
                        Text(pctText)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(pctColor)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }

                // Dual-zone progress bar (Cached + Fresh) with Compaction Threshold tick
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(p.track)
                        Capsule()
                            .fill(p.accentFreshBar)
                            .frame(width: max(totalRatio > 0 ? 3.5 : 0, w * totalRatio))
                        Capsule()
                            .fill(p.accentCacheBar)
                            .frame(width: max(cacheRatio > 0 ? 3.5 : 0, w * cacheRatio))

                        // Compaction threshold marker
                        RoundedRectangle(cornerRadius: 1)
                            .fill(p.accentWarnBar)
                            .frame(width: 2, height: 10)
                            .offset(x: max(0, min(w - 2, w * thresholdRatio - 1)))
                    }
                }
                .frame(height: 6.5)

                HStack(spacing: 6) {
                    metricPair("Cache", "\(Int((state.cacheHitRate * 100).rounded()))%", valueColor: p.accentCacheText, palette: p)
                    Text("·")
                        .font(.system(size: 9.5))
                        .foregroundStyle(p.muted)
                    metricPair("增量", HUDFormatters.formatSignedTokens(state.contextDelta), valueColor: p.numberPrimary, palette: p)
                    Spacer(minLength: 4)
                    metricPair("Out", HUDFormatters.formatTokens(state.lastOutputTokens), valueColor: p.numberPrimary, palette: p)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
    }

    // MARK: - TPS Card

    private func tpsCard(_ p: HUDPalette) -> some View {
        cardContainer(p) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("TPS")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(p.label)
                    Spacer(minLength: 4)
                    if state.isGenerating, let started = state.generatingStartedAt {
                        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                            let elapsed = max(0, ctx.date.timeIntervalSince(started))
                            HStack(alignment: .center, spacing: 6) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(p.accentLiveBar)
                                        .frame(width: 5, height: 5)
                                    Text(String(format: "生成中 %.1fs", elapsed))
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(p.accentLiveText)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(p.accentLiveBar.opacity(0.15))
                                )

                                if let last = state.lastTurnTps {
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text("上轮")
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundStyle(p.label)
                                        Text(HUDFormatters.formatTps(last))
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                            .foregroundStyle(p.numberHero)
                                    }
                                }
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(HUDFormatters.formatTps(state.lastTurnTps))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(p.numberHero)
                            Text("tok/s")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(p.muted)
                        }
                    }
                }

                HStack(spacing: 6) {
                    metricPair("均值", HUDFormatters.formatTps(state.avgTps), valueColor: p.numberPrimary, palette: p)
                    Text("·")
                        .font(.system(size: 9.5))
                        .foregroundStyle(p.muted)
                    metricPair("峰值", HUDFormatters.formatTps(state.peakTps), valueColor: p.numberPrimary, palette: p)
                    Spacer(minLength: 4)
                    metricPair("耗时", HUDFormatters.formatDuration(state.lastTurnDurationSec), valueColor: p.numberPrimary, palette: p)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                if state.recentTps.count >= 2 {
                    TPSSparkline(values: state.recentTps, strokeColor: p.accentChart)
                        .frame(height: 17)
                }
            }
        }
    }

    // MARK: - Compaction Card

    private func compactionCard(_ p: HUDPalette) -> some View {
        let threshold = max(1, state.compactionThreshold)
        let ratio = min(1.0, Double(state.contextTokens) / Double(threshold))
        let remaining = max(0, threshold - state.contextTokens)
        let isExactThreshold = state.thresholdSource == "calibrated" || state.thresholdSource == "override"
        let pctValue = ratio * 100.0
        let pctText = (pctValue >= 99.95 || pctValue <= 0.05)
            ? String(format: "%.0f%%", pctValue)
            : String(format: "%.1f%%", pctValue)
        let barColor: Color = ratio >= 0.9
            ? p.accentDangerBar
            : (ratio >= 0.75 ? p.accentWarnBar : p.accentMintBar)
        let pctColor: Color = ratio >= 0.9
            ? p.accentDangerText
            : (ratio >= 0.75 ? p.accentWarnText : p.accentMintText)

        return cardContainer(p) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context 压缩")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(p.label)
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("阈值")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(p.label)
                        Text("\(isExactThreshold ? "" : "~")\(HUDFormatters.formatTokens(threshold))")
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(p.numberHero)
                        if state.thresholdSource == "override",
                           let raw = state.thresholdOverrideLabel, !raw.isEmpty {
                            Text(raw.hasSuffix("%") ? raw : "ENV")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(p.badgeForeground)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(p.badgeBackground))
                                .help("已由 AGY_CLI_AUTO_COMPACT_OVERRIDE=\(raw) 覆盖")
                        }
                    }
                }

                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(p.track)
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(ratio > 0 ? 3.5 : 0, w * ratio))
                    }
                }
                .frame(height: 5.5)

                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("距触发")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(p.label)
                        Text(HUDFormatters.formatTokens(remaining))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(p.numberHero)
                    }
                    Spacer()
                    Text(pctText)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(pctColor)
                }

                if let ckpt = state.lastCompaction {
                    HStack(spacing: 4) {
                        Text("第 \(state.compactionCount) 次")
                            .fontWeight(.semibold)
                            .foregroundStyle(p.numberPrimary)
                        if let post = ckpt.postTokens {
                            Text("\(HUDFormatters.formatTokens(ckpt.preTokens))→\(HUDFormatters.formatTokens(post))")
                                .fontWeight(.medium)
                                .foregroundStyle(p.numberPrimary)
                        } else {
                            Text("\(HUDFormatters.formatTokens(ckpt.preTokens))→压缩中")
                                .foregroundStyle(p.label)
                        }
                        Spacer()
                        if let saved = ckpt.savedRatio {
                            Text(String(format: "-%.0f%%", saved * 100.0))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(p.accentLiveText)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(p.accentLiveBar.opacity(0.16)))
                        }
                        metricPair("摘要", HUDFormatters.formatTokens(ckpt.summaryTokens), valueColor: p.numberPrimary, palette: p)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                } else {
                    Text("本会话尚未触发压缩")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(p.muted)
                }
            }
        }
    }

    // MARK: - Collapsible Quota Accordion (Collapsed by Default)

    private func quotaAccordionCard(_ p: HUDPalette) -> some View {
        cardContainer(p) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    let expanding = !state.isQuotaExpanded
                    state.isQuotaExpanded.toggle()
                    if expanding {
                        onExpandQuota()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(p.label)
                            .rotationEffect(.degrees(state.isQuotaExpanded ? 90 : 0))
                            .frame(width: 11)

                        Text("配额")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(p.label)
                            .fixedSize()

                        Spacer(minLength: 4)

                        if let quota = state.quota, let active = quota.activeGroup {
                            // Quota is only served by Antigravity desktop's language server,
                            // so a CLI-only session keeps showing the last synced numbers.
                            let isStale = Date().timeIntervalSince(quota.updatedAt) > 600
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Circle()
                                    .fill(p.quotaBarColor(active.headlineFraction).opacity(isStale ? 0.65 : 1.0))
                                    .frame(width: 6, height: 6)
                                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }

                                if let b5h = active.fiveHourBucket, let bWeek = active.weeklyBucket {
                                    HStack(alignment: .firstTextBaseline, spacing: 2.5) {
                                        Text("5h")
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundStyle(p.label)
                                        Text(HUDFormatters.formatQuotaPercent(b5h.remainingFraction))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(p.quotaValueColor(b5h.remainingFraction, stale: isStale))
                                        Text("·")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(p.muted)
                                        Text("周")
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundStyle(p.label)
                                        Text(HUDFormatters.formatQuotaPercent(bWeek.remainingFraction))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(p.quotaValueColor(bWeek.remainingFraction, stale: isStale))
                                    }
                                } else {
                                    Text(HUDFormatters.formatQuotaPercent(active.headlineFraction))
                                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(p.quotaValueColor(active.headlineFraction, stale: isStale))
                                    if !isStale, let reset = active.buckets.first?.resetTime {
                                        Text("· \(HUDFormatters.formatCountdown(reset))")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(p.label)
                                    }
                                }

                                if isStale {
                                    Text("· \(HUDFormatters.formatRelative(quota.updatedAt))")
                                        .font(.system(size: 8.8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(p.muted)
                                        .help("配额由 Antigravity 桌面端同步；仅使用 agy CLI 时不会刷新")
                                }
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        } else if state.isQuotaLoading {
                            Text("同步中...")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(p.label)
                        } else {
                            Text("未同步")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(p.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if state.isQuotaExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle()
                            .fill(p.divider)
                            .frame(height: 0.75)
                            .padding(.top, 7)

                        if let quota = state.quota {
                            HStack(spacing: 6) {
                                Text(quota.tierName)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(p.badgeForeground)
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4.5)
                                            .fill(p.badgeBackground)
                                    )

                                if let ps = quota.planStatus,
                                   let promptCredits = ps.availablePromptCredits {
                                    metricPair("Credits", "\(promptCredits)", valueColor: p.numberPrimary, palette: p)
                                }

                                Spacer()

                                Text(HUDFormatters.formatRelative(quota.updatedAt))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(p.muted)

                                Button(action: onRefreshQuota) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(p.buttonForeground)
                                }
                                .buttonStyle(.plain)
                                .help("刷新配额")
                            }

                            ForEach(Array(quota.groups.enumerated()), id: \.element.id) { idx, group in
                                if idx > 0 {
                                    Rectangle()
                                        .fill(p.divider.opacity(0.7))
                                        .frame(height: 0.75)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        if group.isActiveGroup {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8.5))
                                                .foregroundStyle(p.accentStar)
                                        }
                                        Text(group.name)
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(p.titlePrimary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .help(group.detail)

                                    ForEach(group.buckets) { bucket in
                                        HStack(alignment: .center, spacing: 6) {
                                            VStack(alignment: .leading, spacing: 1.5) {
                                                Text(bucket.shortLabel)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(p.label)

                                                if let resetTime = bucket.resetTime, !resetTime.isEmpty {
                                                    let clock = HUDFormatters.formatClock(resetTime)
                                                    Text("Resets in \(HUDFormatters.formatCountdown(resetTime))\(clock.isEmpty ? "" : " (\(clock))")")
                                                        .font(.system(size: 8.8, design: .monospaced))
                                                        .foregroundStyle(p.muted)
                                                }
                                            }

                                            Spacer()

                                            HStack(alignment: .firstTextBaseline, spacing: 2.5) {
                                                Text(HUDFormatters.formatQuotaPercent(bucket.remainingFraction))
                                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(p.quotaValueColor(bucket.remainingFraction))
                                                Text("left")
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundStyle(p.muted)
                                            }

                                            QuotaRingGauge(
                                                fraction: bucket.remainingFraction,
                                                color: p.quotaBarColor(bucket.remainingFraction),
                                                trackColor: p.track
                                            )
                                        }
                                        .help(bucket.description ?? group.detail)
                                    }
                                }
                            }
                        } else {
                            HStack {
                                Text(state.quotaError ?? "在 Antigravity 中发送消息后将自动同步配额")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(p.label)
                                Spacer()
                                Button(action: onRefreshQuota) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(p.buttonForeground)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Helpers

    private func metricPair(
        _ label: String,
        _ value: String,
        valueColor: Color,
        palette p: HUDPalette
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(p.label)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
        }
    }

    private func statusIndicator(size: CGFloat, palette p: HUDPalette) -> some View {
        let fillColor: Color = state.isGenerating
            ? p.accentLiveBar
            : (state.contextTokens > 0 ? p.accentChart : p.muted)
        return Circle()
            .fill(fillColor)
            .frame(width: size, height: size)
            .shadow(color: state.isGenerating ? p.accentLiveBar.opacity(0.75) : .clear, radius: 3.5)
    }

    private func cardContainer<Content: View>(
        _ p: HUDPalette,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                    .fill(p.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                            .stroke(p.cardBorder, lineWidth: 0.75)
                    )
            )
    }
}

private struct TPSSparkline: View {
    let values: [Double]
    let strokeColor: Color

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let maxVal = max(values.max() ?? 1.0, 1.0)
            let minVal = max(0.0, (values.min() ?? 0.0) * 0.7)
            let span = max(maxVal - minVal, 1.0)

            var linePath = Path()
            var fillPath = Path()
            let stepX = (size.width - 3) / CGFloat(values.count - 1)
            var lastPoint = CGPoint.zero

            for (i, val) in values.enumerated() {
                let x = 1.5 + CGFloat(i) * stepX
                let norm = (val - minVal) / span
                let y = size.height - CGFloat(norm) * (size.height - 4) - 2.0
                let pt = CGPoint(x: x, y: y)
                lastPoint = pt
                if i == 0 {
                    linePath.move(to: pt)
                    fillPath.move(to: CGPoint(x: x, y: size.height))
                    fillPath.addLine(to: pt)
                } else {
                    linePath.addLine(to: pt)
                    fillPath.addLine(to: pt)
                }
            }
            fillPath.addLine(to: CGPoint(x: lastPoint.x, y: size.height))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [strokeColor.opacity(0.32), strokeColor.opacity(0.03)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                linePath,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )

            let dotRect = CGRect(x: lastPoint.x - 2.2, y: lastPoint.y - 2.2, width: 4.4, height: 4.4)
            context.fill(Path(ellipseIn: dotRect), with: .color(strokeColor))
        }
    }
}

private struct QuotaRingGauge: View {
    let fraction: Double
    let color: Color
    let trackColor: Color

    var body: some View {
        let clamped = max(0.0, min(1.0, fraction))
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 2.3)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}
