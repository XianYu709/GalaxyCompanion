import Foundation
#if canImport(GalaxyCompanionProtocol)
import GalaxyCompanionProtocol
#endif

/// A locally-derived sleep-period estimate. It is deliberately limited to a
/// period, duration, and efficiency: it is not a sleep stage, a medical
/// diagnosis, or a reproduction of a Watch vendor's sleep score.
public struct LocalSleepSession: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public let estimatedSleepDuration: TimeInterval
    public let timeInBed: TimeInterval
    /// Closed interval `0...1`, derived from `estimatedSleepDuration / timeInBed`.
    public let efficiency: Double
    public let heartRateSampleCount: Int
    public let activityIntervalCount: Int
    public let analysisVersion: Int

    public init(
        id: UUID,
        startTime: Date,
        endTime: Date,
        estimatedSleepDuration: TimeInterval,
        timeInBed: TimeInterval,
        efficiency: Double,
        heartRateSampleCount: Int,
        activityIntervalCount: Int,
        analysisVersion: Int
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.estimatedSleepDuration = estimatedSleepDuration
        self.timeInBed = timeInBed
        self.efficiency = efficiency
        self.heartRateSampleCount = heartRateSampleCount
        self.activityIntervalCount = activityIntervalCount
        self.analysisVersion = analysisVersion
    }
}

/// Why local sleep analysis declines to produce a result. A missing result is
/// safer than presenting an attractive but ungrounded sleep number.
public enum LocalSleepAnalysisUnavailableReason: Equatable, Sendable {
    case noSynchronizedData
    case insufficientHeartRateSamples(required: Int, actual: Int)
    case insufficientHeartRateCoverage(requiredMinutes: Int, actualMinutes: Int)
    case heartRateCoverageGap(minutes: Int)
    case missingGranularActivity
    case implausibleRestPeriod
}

public enum LocalSleepAnalysis: Equatable, Sendable {
    case estimated(LocalSleepSession)
    case unavailable(LocalSleepAnalysisUnavailableReason)
}

/// Conservative v1 local analysis over app-owned Watch data.
///
/// Health Services may batch passive updates at device-chosen intervals, so
/// this type does not assume a fixed sensor cadence. It accepts only a night
/// with enough real heart-rate coverage and at least one granular activity
/// delta. Daily cumulative steps and distance are intentionally ignored here:
/// a day total has no trustworthy intra-night activity timing.
public enum LocalSleepAnalyzer {
    public static let analysisVersion = 1
    public static let minimumHeartRateSampleCount = 4
    public static let minimumHeartRateCoverage: TimeInterval = 3 * 60 * 60
    public static let maximumHeartRateGap: TimeInterval = 2 * 60 * 60
    public static let maximumActivityInterval: TimeInterval = 30 * 60
    public static let minimumEstimatedSleep: TimeInterval = 2 * 60 * 60

    public static func analyze(
        samples: [HealthSample],
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> LocalSleepAnalysis {
        guard !samples.isEmpty else { return .unavailable(.noSynchronizedData) }
        let analysisWindow = mostRecentNightWindow(at: now, calendar: calendar)

        let heartRates = samples
            .filter {
                $0.metric == .heartRate &&
                    $0.source != .demo &&
                    $0.quality != .unreliable &&
                    $0.value.isFinite &&
                    (30...240).contains($0.value) &&
                    analysisWindow.contains(timestamp(of: $0))
            }
            .sorted { timestamp(of: $0) < timestamp(of: $1) }

        guard heartRates.count >= minimumHeartRateSampleCount else {
            return .unavailable(
                .insufficientHeartRateSamples(
                    required: minimumHeartRateSampleCount,
                    actual: heartRates.count
                )
            )
        }
        guard let firstHeartRate = heartRates.first, let lastHeartRate = heartRates.last else {
            return .unavailable(.insufficientHeartRateSamples(required: minimumHeartRateSampleCount, actual: 0))
        }

        let heartRateCoverage = timestamp(of: lastHeartRate).timeIntervalSince(timestamp(of: firstHeartRate))
        guard heartRateCoverage >= minimumHeartRateCoverage else {
            return .unavailable(
                .insufficientHeartRateCoverage(
                    requiredMinutes: Int(minimumHeartRateCoverage / 60),
                    actualMinutes: Int(heartRateCoverage / 60)
                )
            )
        }

        let widestGap = zip(heartRates, heartRates.dropFirst())
            .map { timestamp(of: $1).timeIntervalSince(timestamp(of: $0)) }
            .max() ?? 0
        guard widestGap <= maximumHeartRateGap else {
            return .unavailable(.heartRateCoverageGap(minutes: Int(widestGap / 60)))
        }

        let allGranularActivity = samples.filter { sample in
            guard sample.source != .demo,
                  sample.quality != .unreliable,
                  sample.aggregation == .interval,
                  (sample.metric == .steps || sample.metric == .distance),
                  sample.value.isFinite,
                  sample.value >= 0,
                  let endTime = sample.endTime,
                  endTime >= sample.startTime else {
                return false
            }
            let duration = endTime.timeIntervalSince(sample.startTime)
            return duration <= maximumActivityInterval &&
                analysisWindow.intersects(DateInterval(start: sample.startTime, end: endTime))
        }
        guard !allGranularActivity.isEmpty else {
            return .unavailable(.missingGranularActivity)
        }

        // Padding recognizes that a passive heart-rate reading is an
        // observation inside a rest period, not necessarily the exact moment
        // a person fell asleep or woke up. The fixed, documented 15 minutes is
        // deliberately modest and never creates a vendor-style sleep score.
        let restStart = max(
            analysisWindow.start,
            timestamp(of: firstHeartRate).addingTimeInterval(-15 * 60)
        )
        let restEnd = min(
            analysisWindow.end,
            timestamp(of: lastHeartRate).addingTimeInterval(15 * 60)
        )
        let timeInBed = restEnd.timeIntervalSince(restStart)
        guard timeInBed >= minimumHeartRateCoverage else {
            return .unavailable(.implausibleRestPeriod)
        }

        let activeRanges = allGranularActivity.compactMap { sample -> DateInterval? in
            guard isMaterialActivity(sample), let endTime = sample.endTime else { return nil }
            let padded = DateInterval(
                start: sample.startTime.addingTimeInterval(-5 * 60),
                end: endTime.addingTimeInterval(5 * 60)
            )
            return padded.intersection(with: DateInterval(start: restStart, end: restEnd))
        }
        let awakeDuration = mergedDuration(of: activeRanges)
        let estimatedSleepDuration = max(0, timeInBed - awakeDuration)
        let efficiency = estimatedSleepDuration / timeInBed
        guard estimatedSleepDuration >= minimumEstimatedSleep, efficiency >= 0.5 else {
            return .unavailable(.implausibleRestPeriod)
        }

        return .estimated(
            LocalSleepSession(
                // This identifier is deterministic for a stable window and
                // analysis version; rebuilding the UI cannot create copies.
                id: stableID(start: restStart, end: restEnd),
                startTime: restStart,
                endTime: restEnd,
                estimatedSleepDuration: estimatedSleepDuration,
                timeInBed: timeInBed,
                efficiency: efficiency,
                heartRateSampleCount: heartRates.count,
                activityIntervalCount: allGranularActivity.count,
                analysisVersion: analysisVersion
            )
        )
    }

    private static func mostRecentNightWindow(at now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let fourAM = calendar.date(byAdding: .hour, value: 4, to: today)!
        let analysisDay: Date
        let end: Date
        if now >= fourAM {
            analysisDay = today
            let twoPM = calendar.date(byAdding: .hour, value: 14, to: today)!
            end = min(now, twoPM)
        } else {
            analysisDay = calendar.date(byAdding: .day, value: -1, to: today)!
            end = calendar.date(byAdding: .hour, value: 14, to: analysisDay)!
        }
        let previousDay = calendar.date(byAdding: .day, value: -1, to: analysisDay)!
        let start = calendar.date(byAdding: .hour, value: 18, to: previousDay)!
        return DateInterval(start: start, end: end)
    }

    private static func timestamp(of sample: HealthSample) -> Date {
        sample.endTime ?? sample.startTime
    }

    private static func isMaterialActivity(_ sample: HealthSample) -> Bool {
        switch sample.metric {
        case .steps:
            sample.value >= 20
        case .distance:
            sample.value >= 12
        default:
            false
        }
    }

    private static func mergedDuration(of intervals: [DateInterval]) -> TimeInterval {
        let ordered = intervals.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0

        for interval in ordered.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    private static func stableID(start: Date, end: Date) -> UUID {
        // UUID v5 would need an extra dependency. The fixed byte layout below
        // is a deterministic, non-security identifier used only for SwiftUI.
        let startMilliseconds = UInt64(max(0, start.timeIntervalSince1970 * 1_000))
        let endMilliseconds = UInt64(max(0, end.timeIntervalSince1970 * 1_000))
        let bytes: [UInt8] = [
            0x47, 0x43, 0x53, UInt8(analysisVersion),
            UInt8((startMilliseconds >> 56) & 0xff), UInt8((startMilliseconds >> 48) & 0xff),
            UInt8((startMilliseconds >> 40) & 0xff), UInt8((startMilliseconds >> 32) & 0xff),
            UInt8((startMilliseconds >> 24) & 0xff), UInt8((startMilliseconds >> 16) & 0xff),
            UInt8((startMilliseconds >> 8) & 0xff), UInt8(startMilliseconds & 0xff),
            UInt8((endMilliseconds >> 56) & 0xff), UInt8((endMilliseconds >> 48) & 0xff),
            UInt8((endMilliseconds >> 40) & 0xff), UInt8((endMilliseconds >> 32) & 0xff)
        ]
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
