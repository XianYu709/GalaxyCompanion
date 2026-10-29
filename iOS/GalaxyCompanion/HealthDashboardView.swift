import Foundation
import SwiftUI

struct HealthDashboardView: View {
    let appState: AppState

    var body: some View {
        ZStack {
            NightCurrentBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    CurrentSectionHeader(
                        eyebrow: "本机健康数据",
                        title: "只显示已安全同步的记录。",
                        detail: healthSubtitle
                    )

                    syncActions

                    if appState.healthSamples.isEmpty {
                        emptyHealthState
                    } else {
                        latestMetrics
                        sleepAnalysis
                        recentMeasurements
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                // Reserve the translucent system tab bar instead of letting
                // the final HealthKit action disappear below it.
                .padding(.bottom, 116)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var healthSubtitle: String {
        if appState.healthSamples.isEmpty {
            return "Watch 离线期间的数据会先保留在手表，连接后由你主动同步。"
        }
        return "数据存在 iPhone 本地。Apple Health 写入始终由你单独确认。"
    }

    private var syncActions: some View {
        CurrentCard(title: "同步与写入", symbol: "arrow.triangle.2.circlepath", tint: NightCurrent.mint) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appState.canSynchronize ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(appState.canSynchronize ? NightCurrent.mint : NightCurrent.amber)
                Text(appState.canSynchronize ? "当前连接已满足安全同步条件。" : appState.syncRequirementDetail)
                    .font(.footnote)
                    .foregroundStyle(NightCurrent.muted)
            }
            CurrentPrimaryButton(
                "同步到 iPhone",
                symbol: "arrow.down.circle.fill",
                tint: appState.canSynchronize ? NightCurrent.mint : NightCurrent.amber,
                isLoading: appState.isSyncing,
                action: appState.synchronizeHealth
            )
            .disabled(!appState.canSynchronize)
            .opacity(appState.canSynchronize ? 1 : 0.55)

            Divider().overlay(Color.white.opacity(0.10))
            Text(appState.healthSyncStatus.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(syncStatusTint)
            Text(appState.healthSyncStatus.detail)
                .font(.caption)
                .foregroundStyle(NightCurrent.muted)
            Text(appState.watchLocalRecordingDetail)
                .font(.caption)
                .foregroundStyle(NightCurrent.blue)

            Button(action: appState.exportToAppleHealth) {
                HStack {
                    if appState.isExporting {
                        ProgressView().tint(NightCurrent.mint)
                    } else {
                        Image(systemName: "heart.fill")
                    }
                    Text("写入 Apple Health")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.headline.weight(.semibold))
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.canExportToAppleHealth ? NightCurrent.mint : NightCurrent.muted)
            .background(
                appState.canExportToAppleHealth ? NightCurrent.mint.opacity(0.12) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .disabled(!appState.canExportToAppleHealth)

            if !appState.canExportToAppleHealth {
                Text(appState.appleHealthExportRequirementDetail)
                    .font(.caption)
                    .foregroundStyle(NightCurrent.muted)
            }

            Text(appState.healthKitExportStatus.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NightCurrent.fog)
            Text(appState.healthKitExportStatus.detail)
                .font(.caption)
                .foregroundStyle(NightCurrent.muted)
        }
    }

    private var emptyHealthState: some View {
        CurrentCard(title: "等待第一笔真实数据", symbol: "waveform.path.ecg", tint: NightCurrent.blue) {
            ContentUnavailableView {
                Label("还没有同步的健康记录", systemImage: "heart.slash")
            } description: {
                Text(appState.watchLocalRecordingDetail)
            }
            .foregroundStyle(NightCurrent.muted)
        }
    }

    private var syncStatusTint: Color {
        switch appState.healthSyncStatus {
        case .ready, .synced: NightCurrent.mint
        case .syncing: NightCurrent.blue
        case .blocked, .unavailable: NightCurrent.amber
        case .failed: NightCurrent.rose
        }
    }

    private var latestMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近记录")
                .font(.title3.weight(.bold))
                .foregroundStyle(NightCurrent.fog)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                MetricTile(metric: .heartRate, sample: latestSample(for: .heartRate))
                MetricTile(
                    metric: .steps,
                    sample: latestSample(for: .steps, aggregation: .dailyCumulative)
                )
                MetricTile(
                    metric: .distance,
                    sample: latestSample(for: .distance, aggregation: .dailyCumulative)
                )
                MetricTile(metric: .totalCalories, sample: latestSample(for: .totalCalories))
            }
            Label(
                "日总能量包含基础代谢，只在本应用展示，不写入 Apple Health。",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(NightCurrent.amber)
        }
    }

    private var recentMeasurements: some View {
        CurrentCard(title: "同步记录", symbol: "clock.arrow.circlepath", tint: NightCurrent.blue) {
            ForEach(recentSamples) { sample in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(sample.displayName, systemImage: sample.metric.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NightCurrent.fog)
                        Spacer()
                        Text(sample.formattedValue)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(NightCurrent.mint)
                    }
                    HStack(spacing: 8) {
                        Text(sample.endTimeOrStart.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                        Text(sample.quality.displayName)
                        Text("·")
                        Text(sample.source.displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(NightCurrent.muted)
                }
                if sample.id != recentSamples.last?.id {
                    Divider().overlay(Color.white.opacity(0.10))
                }
            }
        }
    }

    private var sleepAnalysis: some View {
        CurrentCard(title: "睡眠（本地估算）", symbol: "moon.stars.fill", tint: NightCurrent.blue) {
            switch appState.sleepAnalysis {
            case .estimated(let session):
                Text("最近夜间的休息估算")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NightCurrent.fog)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("预计睡眠")
                            .font(.caption)
                            .foregroundStyle(NightCurrent.muted)
                        Text(session.estimatedSleepDuration.sleepDurationLabel)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(NightCurrent.mint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("睡眠效率")
                            .font(.caption)
                            .foregroundStyle(NightCurrent.muted)
                        Text(session.efficiency, format: .percent.precision(.fractionLength(0)))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(NightCurrent.fog)
                    }
                }
                Divider().overlay(Color.white.opacity(0.10))
                KeyValueRow(
                    label: "休息时段",
                    value: "\(session.startTime.formatted(date: .omitted, time: .shortened)) – \(session.endTime.formatted(date: .omitted, time: .shortened))"
                )
                KeyValueRow(label: "卧床时长", value: session.timeInBed.sleepDurationLabel)
                Text("依据 \(session.heartRateSampleCount) 条低频心率与 \(session.activityIntervalCount) 段活动增量推断。不会复刻三星睡眠分期或评分。")
                    .font(.caption)
                    .foregroundStyle(NightCurrent.muted)

            case .unavailable(let reason):
                Label("尚未生成睡眠估算", systemImage: "moon.zzz")
                    .font(.headline)
                    .foregroundStyle(NightCurrent.fog)
                Text(reason.displayText)
                    .font(.footnote)
                    .foregroundStyle(NightCurrent.muted)
                Text("需要同一夜间的真实后台心率与细粒度步数或距离增量；日累计步数不能用于还原夜间活动。")
                    .font(.caption)
                    .foregroundStyle(NightCurrent.amber)
            }

            Button("分析最近夜间") { appState.analyzeLatestSleep() }
                .buttonStyle(.bordered)
                .tint(NightCurrent.blue)
        }
    }

    private var recentSamples: [HealthSample] {
        Array(appState.healthSamples.sorted { $0.endTimeOrStart > $1.endTimeOrStart }.prefix(8))
    }

    private func latestSample(
        for metric: HealthMetric,
        aggregation: HealthSampleAggregation? = nil
    ) -> HealthSample? {
        appState.healthSamples
            .filter { $0.metric == metric && (aggregation == nil || $0.aggregation == aggregation) }
            .max { $0.endTimeOrStart < $1.endTimeOrStart }
    }
}

private struct MetricTile: View {
    let metric: HealthMetric
    let sample: HealthSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: metric.symbol)
                .foregroundStyle(tileTint)
                .font(.title3)
            Text(metric.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(NightCurrent.muted)
            if let sample {
                Text(sample.formattedValue)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(NightCurrent.fog)
                    .minimumScaleFactor(0.75)
                Text(sample.endTimeOrStart.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NightCurrent.muted)
            } else {
                Text("尚无记录")
                    .font(.subheadline)
                    .foregroundStyle(NightCurrent.muted)
                Text("等待同步")
                    .font(.caption)
                    .foregroundStyle(NightCurrent.muted.opacity(0.75))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var tileTint: Color {
        metric == .totalCalories ? NightCurrent.amber : NightCurrent.mint
    }
}

private extension HealthSample {
    var endTimeOrStart: Date { endTime ?? startTime }

    var displayName: String {
        switch (metric, aggregation) {
        case (.steps, .interval): "步数增量"
        case (.distance, .interval): "距离增量"
        default: metric.displayName
        }
    }

    var formattedValue: String {
        switch metric {
        case .steps, .floors:
            return "\(Int(value.rounded())) \(unit.displayName)"
        case .heartRate:
            return "\(Int(value.rounded())) 次/分"
        case .distance:
            if value >= 1_000 {
                return String(format: "%.2f km", value / 1_000)
            }
            return "\(Int(value.rounded())) m"
        case .totalCalories, .activeCalories:
            return "\(Int(value.rounded())) kcal"
        default:
            return "\(value.formatted(.number.precision(.fractionLength(1)))) \(unit.displayName)"
        }
    }
}

private extension TimeInterval {
    var sleepDurationLabel: String {
        let totalMinutes = max(0, Int((self / 60).rounded()))
        return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分"
    }
}

private extension LocalSleepAnalysisUnavailableReason {
    var displayText: String {
        switch self {
        case .noSynchronizedData:
            "还没有已安全同步到 iPhone 的真实健康数据。"
        case .insufficientHeartRateSamples(let required, let actual):
            "最近夜间仅有 \(actual) 条有效心率；至少需要 \(required) 条。"
        case .insufficientHeartRateCoverage(let requiredMinutes, let actualMinutes):
            "最近夜间心率覆盖 \(actualMinutes) 分钟；至少需要 \(requiredMinutes) 分钟。"
        case .heartRateCoverageGap(let minutes):
            "心率采样中出现 \(minutes) 分钟空档，无法安全推断整段睡眠。"
        case .missingGranularActivity:
            "尚未同步同一夜间的细粒度步数或距离增量。"
        case .implausibleRestPeriod:
            "现有信号不能形成可信的连续休息时段。"
        }
    }
}

private extension HealthMetric {
    var displayName: String {
        switch self {
        case .heartRate: "心率"
        case .steps: "日累计步数"
        case .distance: "日累计距离"
        case .totalCalories: "日总能量"
        case .activeCalories: "活动能量"
        case .floors: "楼层"
        case .spo2: "血氧"
        case .skinTemperature: "皮温"
        case .bodyTemperature: "体温"
        case .ibi: "IBI"
        case .hrv: "HRV"
        case .respiratoryRate: "呼吸率"
        }
    }

    var symbol: String {
        switch self {
        case .heartRate: "heart.fill"
        case .steps: "figure.walk"
        case .distance: "point.topleft.down.curvedto.point.bottomright.up"
        case .totalCalories, .activeCalories: "flame.fill"
        case .floors: "stairs"
        case .spo2: "drop.fill"
        case .skinTemperature, .bodyTemperature: "thermometer.medium"
        case .ibi, .hrv: "waveform.path.ecg"
        case .respiratoryRate: "wind"
        }
    }
}

private extension HealthUnit {
    var displayName: String {
        switch self {
        case .count: "次"
        case .beatsPerMinute: "次/分"
        case .milliseconds: "ms"
        case .kilocalories: "kcal"
        case .meters: "m"
        case .percent: "%"
        case .celsius: "°C"
        case .breathsPerMinute: "次/分"
        }
    }
}

private extension SampleQuality {
    var displayName: String {
        switch self {
        case .measured: "实测"
        case .estimated: "估算"
        case .unreliable: "质量受限"
        case .unknown: "未标注"
        }
    }
}

private extension HealthSampleSource {
    var displayName: String {
        switch self {
        case .wearHealthServices: "Wear Health Services"
        case .samsungHealthSensor: "Samsung Sensor"
        case .derived: "本地分析"
        case .demo: "开发样本"
        }
    }
}
