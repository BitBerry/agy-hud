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

struct HUDView: View {
    @ObservedObject var state: HUDState
    let onRefreshQuota: () -> Void
    let onExpandQuota: () -> Void
    let onToggleMiniPill: () -> Void
    let onSizeChange: (CGSize) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cornerRadius: CGFloat = state.isMiniPill ? 17 : 14
        Group {
            if state.isMiniPill {
                miniPillBody
            } else {
                fullCardBody
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .circular))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12),
                    lineWidth: 0.75
                )
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

    private var miniPillBody: some View {
        let threshold = max(1, state.compactionThreshold)
        let thresholdPrefix = state.thresholdSource == "calibrated" ? "" : "~"
        let thresholdText = "\(thresholdPrefix)\(HUDFormatters.formatTokens(threshold))"
        let remainingTokens = max(0, threshold - state.contextTokens)
        let remainingRatio = max(0.0, min(1.0, Double(remainingTokens) / Double(threshold)))
        let remainingPct = Int((remainingRatio * 100.0).rounded())
        let remainingColor: Color = remainingRatio <= 0.10 ? .red : (remainingRatio <= 0.25 ? .orange : .mint)

        return HStack(spacing: 7) {
            statusIndicator(size: 7)

            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(HUDFormatters.formatTokens(state.contextTokens))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("/\(thresholdText)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .help("当前 Context / 压缩阈值 \(thresholdText)")

            pillDivider

            Text("压剩 \(remainingPct)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(remainingColor)
                .help("距压缩阈值 \(thresholdText) 剩余 \(HUDFormatters.formatTokens(remainingTokens)) (\(remainingPct)%)")

            pillDivider

            Text("\(HUDFormatters.formatTps(state.lastTurnTps)) t/s")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            if let activeQuota = state.quota?.activeGroup {
                pillDivider
                HStack(spacing: 3) {
                    Circle()
                        .fill(quotaColor(activeQuota.headlineFraction))
                        .frame(width: 5, height: 5)
                    Text(HUDFormatters.formatQuotaPercent(activeQuota.headlineFraction))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                onToggleMiniPill()
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("展开悬浮窗")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 34)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 11)
    }

    // MARK: - Full Card Mode

    private var fullCardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection
            contextCard
            tpsCard
            compactionCard
            quotaAccordionCard
        }
        .padding(10)
        .frame(width: 272, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var headerSection: some View {
        HStack(spacing: 6) {
            statusIndicator(size: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.modelDisplayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(state.conversationTitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button(action: onToggleMiniPill) {
                Image(systemName: "minus")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("折叠为迷你药丸")
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Context Length Card

    private var contextCard: some View {
        let totalWindow = max(1, state.contextWindow)
        let totalRatio = min(1.0, Double(state.contextTokens) / Double(totalWindow))
        let cacheRatio = min(totalRatio, Double(state.cacheReadTokens) / Double(totalWindow))
        let thresholdRatio = min(1.0, Double(state.compactionThreshold) / Double(totalWindow))
        let pctText = String(format: "%.1f%%", totalRatio * 100.0)

        return cardContainer {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context 长度")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(HUDFormatters.formatTokens(state.contextTokens))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text("/ \(HUDFormatters.formatTokens(totalWindow))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("(\(pctText))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(totalRatio > 0.7 ? .orange : .secondary)
                    }
                }

                // Dual-zone progress bar (Cached + Fresh) with Compaction Threshold tick
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(Color.indigo.opacity(0.85))
                            .frame(width: max(totalRatio > 0 ? 3 : 0, w * totalRatio))
                        Capsule()
                            .fill(Color.cyan)
                            .frame(width: max(cacheRatio > 0 ? 3 : 0, w * cacheRatio))

                        // Compaction threshold marker
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 1.5, height: 10)
                            .offset(x: max(0, min(w - 2, w * thresholdRatio - 0.75)))
                    }
                }
                .frame(height: 6)

                HStack(spacing: 8) {
                    Text("Cache \(Int((state.cacheHitRate * 100).rounded()))%")
                        .foregroundStyle(Color.cyan)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("增量 \(HUDFormatters.formatSignedTokens(state.contextDelta))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Out \(HUDFormatters.formatTokens(state.lastOutputTokens))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 9.5, design: .monospaced))
            }
        }
    }

    // MARK: - TPS Card

    private var tpsCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TPS")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.isGenerating, let started = state.generatingStartedAt {
                        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                            let elapsed = max(0, ctx.date.timeIntervalSince(started))
                            HStack(spacing: 4) {
                                Text(String(format: "生成中 %.1fs", elapsed))
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)
                                if let last = state.lastTurnTps {
                                    Text("· 上轮 \(HUDFormatters.formatTps(last))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(HUDFormatters.formatTps(state.lastTurnTps))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text("tok/s")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("均值 \(HUDFormatters.formatTps(state.avgTps))")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("峰值 \(HUDFormatters.formatTps(state.peakTps))")
                    Spacer()
                    Text("耗时 \(HUDFormatters.formatDuration(state.lastTurnDurationSec))")
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)

                if state.recentTps.count >= 2 {
                    TPSSparkline(values: state.recentTps)
                        .frame(height: 16)
                }
            }
        }
    }

    // MARK: - Compaction Card

    private var compactionCard: some View {
        let threshold = max(1, state.compactionThreshold)
        let ratio = min(1.0, Double(state.contextTokens) / Double(threshold))
        let remaining = max(0, threshold - state.contextTokens)
        let barColor: Color = ratio >= 0.9 ? .red : (ratio >= 0.75 ? .orange : .mint)

        return cardContainer {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context 压缩")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("阈值 \(state.thresholdSource == "calibrated" ? "" : "~")\(HUDFormatters.formatTokens(threshold))")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(ratio > 0 ? 3 : 0, w * ratio))
                    }
                }
                .frame(height: 5)

                HStack {
                    Text("距触发 \(HUDFormatters.formatTokens(remaining))")
                    Spacer()
                    Text("\(Int((ratio * 100).rounded()))%")
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)

                if let ckpt = state.lastCompaction {
                    HStack(spacing: 4) {
                        Text("第 \(state.compactionCount) 次")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        if let post = ckpt.postTokens {
                            Text("\(HUDFormatters.formatTokens(ckpt.preTokens))→\(HUDFormatters.formatTokens(post))")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(HUDFormatters.formatTokens(ckpt.preTokens))→压缩中")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let saved = ckpt.savedRatio {
                            Text(String(format: "-%.0f%%", saved * 100.0))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.16)))
                        }
                        Text("摘要 \(HUDFormatters.formatTokens(ckpt.summaryTokens))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                } else {
                    Text("本会话尚未触发压缩")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Collapsible Quota Accordion (Collapsed by Default)

    private var quotaAccordionCard: some View {
        cardContainer {
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
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(state.isQuotaExpanded ? 90 : 0))
                            .frame(width: 12)

                        Text("配额")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let active = state.quota?.activeGroup {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(quotaColor(active.headlineFraction))
                                    .frame(width: 6, height: 6)

                                if let b5h = active.fiveHourBucket, let bWeek = active.weeklyBucket {
                                    Text("5h \(HUDFormatters.formatQuotaPercent(b5h.remainingFraction)) · 周 \(HUDFormatters.formatQuotaPercent(bWeek.remainingFraction))")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                } else {
                                    Text(HUDFormatters.formatQuotaPercent(active.headlineFraction))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    if let reset = active.buckets.first?.resetTime {
                                        Text("· \(HUDFormatters.formatCountdown(reset))")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else if state.isQuotaLoading {
                            Text("同步中...")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未同步")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if state.isQuotaExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .padding(.top, 6)

                        if let quota = state.quota {
                            HStack(spacing: 6) {
                                Text(quota.tierName)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.accentColor.opacity(0.14))
                                    )

                                if let ps = quota.planStatus,
                                   let promptCredits = ps.availablePromptCredits {
                                    Text("Credits \(promptCredits)")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(HUDFormatters.formatRelative(quota.updatedAt))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)

                                Button(action: onRefreshQuota) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("刷新配额")
                            }

                            ForEach(Array(quota.groups.enumerated()), id: \.element.id) { idx, group in
                                if idx > 0 {
                                    Divider()
                                        .opacity(0.6)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        if group.isActiveGroup {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.yellow)
                                        }
                                        Text(group.name)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .help(group.detail)

                                    ForEach(group.buckets) { bucket in
                                        HStack(alignment: .center, spacing: 6) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(bucket.shortLabel)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(.secondary)

                                                if let resetTime = bucket.resetTime, !resetTime.isEmpty {
                                                    let clock = HUDFormatters.formatClock(resetTime)
                                                    Text("Resets in \(HUDFormatters.formatCountdown(resetTime))\(clock.isEmpty ? "" : " (\(clock))")")
                                                        .font(.system(size: 8.8, design: .monospaced))
                                                        .foregroundStyle(.tertiary)
                                                }
                                            }

                                            Spacer()

                                            Text("\(HUDFormatters.formatQuotaPercent(bucket.remainingFraction)) left")
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.primary)

                                            QuotaRingGauge(
                                                fraction: bucket.remainingFraction,
                                                color: quotaColor(bucket.remainingFraction)
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
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(action: onRefreshQuota) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
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

    private func statusIndicator(size: CGFloat) -> some View {
        Circle()
            .fill(state.isGenerating ? Color.green : (state.contextTokens > 0 ? Color.blue : Color.gray))
            .frame(width: size, height: size)
            .shadow(color: state.isGenerating ? Color.green.opacity(0.6) : .clear, radius: 3)
    }

    private func quotaColor(_ fraction: Double) -> Color {
        if fraction > 0.5 { return .green }
        if fraction > 0.2 { return .orange }
        return .red
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
                    )
            )
    }
}

private struct TPSSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let maxVal = max(values.max() ?? 1.0, 1.0)
            let minVal = max(0.0, (values.min() ?? 0.0) * 0.7)
            let span = max(maxVal - minVal, 1.0)

            var linePath = Path()
            var fillPath = Path()
            let stepX = size.width / CGFloat(values.count - 1)

            for (i, val) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let norm = (val - minVal) / span
                let y = size.height - CGFloat(norm) * (size.height - 3) - 1.5
                if i == 0 {
                    linePath.move(to: CGPoint(x: x, y: y))
                    fillPath.move(to: CGPoint(x: x, y: size.height))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    linePath.addLine(to: CGPoint(x: x, y: y))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                }
            }
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [Color.accentColor.opacity(0.26), Color.accentColor.opacity(0.02)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(linePath, with: .color(Color.accentColor.opacity(0.85)), lineWidth: 1.4)
        }
    }
}

private struct QuotaRingGauge: View {
    let fraction: Double
    let color: Color

    var body: some View {
        let clamped = max(0.0, min(1.0, fraction))
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.14), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}
