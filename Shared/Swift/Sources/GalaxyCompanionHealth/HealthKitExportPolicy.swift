import Foundation
#if canImport(GalaxyCompanionProtocol)
import GalaxyCompanionProtocol
#endif

/// A deliberately small, HealthKit-free description of the quantity types
/// GalaxyCompanion may export. Keeping it outside the HealthKit adapter makes
/// the medical-data policy testable on macOS and prevents unsupported Watch
/// metrics from accidentally becoming exportable when new sensor work lands.
public enum AppleHealthQuantityType: String, CaseIterable, Codable, Hashable, Sendable {
    case stepCount
    case heartRate
    case activeEnergyBurned
    case distanceWalkingRunning
    case flightsClimbed
    case oxygenSaturation
    case bodyTemperature
}

/// Canonical units expected by the iOS HealthKit adapter. In particular,
/// `percent` is a fraction in the closed interval (0, 1], matching
/// `HKUnit.percent()` (for example, 0.97 means 97%).
public enum AppleHealthUnit: String, Codable, Hashable, Sendable {
    case count
    case countPerMinute
    case kilocalorie
    case meter
    case percent
    case degreeCelsius
}

/// Stable metadata carried into the platform adapter. The adapter translates
/// these values to `HKMetadataKeySyncIdentifier`, `HKMetadataKeySyncVersion`,
/// `HKMetadataKeyExternalUUID`, and a reverse-DNS GalaxyCompanion key.
public struct AppleHealthSampleMetadata: Equatable, Sendable {
    public let syncIdentifier: String
    public let syncVersion: Int
    public let externalUUID: String
    public let source: String

    public init(
        syncIdentifier: String,
        syncVersion: Int,
        externalUUID: String,
        source: String
    ) {
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.externalUUID = externalUUID
        self.source = source
    }
}

/// A platform-neutral export request. It intentionally contains no
/// `HKObject`, so it can be validated before a HealthKit store is touched.
public struct AppleHealthSamplePayload: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let quantityType: AppleHealthQuantityType
    public let unit: AppleHealthUnit
    public let value: Double
    public let startDate: Date
    public let endDate: Date
    public let metadata: AppleHealthSampleMetadata

    public init(
        id: UUID,
        quantityType: AppleHealthQuantityType,
        unit: AppleHealthUnit,
        value: Double,
        startDate: Date,
        endDate: Date,
        metadata: AppleHealthSampleMetadata
    ) {
        self.id = id
        self.quantityType = quantityType
        self.unit = unit
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
        self.metadata = metadata
    }
}

public enum AppleHealthSampleMappingError: Error, Equatable, Sendable {
    case developmentSampleRejected
    case unsupportedMetric(HealthMetric)
    case skinTemperatureIsNotBodyTemperature
    case unexpectedUnit(metric: HealthMetric, received: HealthUnit, expected: HealthUnit)
    case invalidValue(metric: HealthMetric)
    case invalidTimeRange
}

/// The sole policy for mapping protocol samples into Apple Health quantities.
/// Every case is explicit; there is deliberately no raw-value fallback.
public enum AppleHealthSampleMapper {
    /// The current Watch collector can produce heart rate, steps, distance
    /// and floors with a safe HealthKit meaning. Keep the system consent
    /// prompt to that concrete minimum; future sensor modules request their
    /// own additional types only after they exist and pass their mapping PoC.
    public static let authorizationQuantityTypes: Set<AppleHealthQuantityType> = [
        .stepCount,
        .heartRate,
        .distanceWalkingRunning,
        .flightsClimbed
    ]

    /// Types the mapper understands. This is intentionally broader than the
    /// current consent set so adding a future provider does not silently
    /// weaken the value-level mapping policy.
    public static let supportedQuantityTypes: Set<AppleHealthQuantityType> = Set(
        AppleHealthQuantityType.allCases
    )

    public static func map(
        _ sample: HealthSample
    ) -> Result<AppleHealthSamplePayload, AppleHealthSampleMappingError> {
        guard sample.source != .demo else {
            return .failure(.developmentSampleRejected)
        }
        guard sample.value.isFinite, isValueValid(sample.value, for: sample.metric) else {
            return .failure(.invalidValue(metric: sample.metric))
        }

        let endDate = sample.endTime ?? sample.startTime
        guard endDate >= sample.startTime else {
            return .failure(.invalidTimeRange)
        }

        let mapping: (AppleHealthQuantityType, AppleHealthUnit, HealthUnit)
        switch sample.metric {
        case .steps:
            mapping = (.stepCount, .count, .count)
        case .heartRate:
            mapping = (.heartRate, .countPerMinute, .beatsPerMinute)
        case .activeCalories:
            mapping = (.activeEnergyBurned, .kilocalorie, .kilocalories)
        case .totalCalories:
            // Wear OS `CALORIES_DAILY` is not an active-energy measurement.
            // Do not write it as `HKQuantityTypeIdentifierActiveEnergyBurned`.
            return .failure(.unsupportedMetric(sample.metric))
        case .distance:
            mapping = (.distanceWalkingRunning, .meter, .meters)
        case .floors:
            mapping = (.flightsClimbed, .count, .count)
        case .spo2:
            mapping = (.oxygenSaturation, .percent, .percent)
        case .bodyTemperature:
            mapping = (.bodyTemperature, .degreeCelsius, .celsius)
        case .skinTemperature:
            // A skin-temperature reading is not clinically equivalent to a
            // body-temperature measurement. A future calibrated metric can
            // use `.bodyTemperature`; this one must never be relabelled.
            return .failure(.skinTemperatureIsNotBodyTemperature)
        case .ibi, .hrv, .respiratoryRate:
            return .failure(.unsupportedMetric(sample.metric))
        }

        guard sample.unit == mapping.2 else {
            return .failure(
                .unexpectedUnit(
                    metric: sample.metric,
                    received: sample.unit,
                    expected: mapping.2
                )
            )
        }

        let canonicalID = sample.id.uuidString.lowercased()
        let metadata = AppleHealthSampleMetadata(
            syncIdentifier: "com.galaxycompanion.health.sample.\(canonicalID)",
            // Apple Health uses the sync identifier/version pair to replace a
            // corrected value without creating a second measurement. Revision
            // 0 is legacy pre-revision wire data, so it remains version 1.
            syncVersion: Int(min(max(sample.revision, 1), Int64(Int.max))),
            externalUUID: canonicalID,
            source: "GalaxyCompanion.\(sample.source.rawValue)"
        )
        return .success(
            AppleHealthSamplePayload(
                id: sample.id,
                quantityType: mapping.0,
                unit: mapping.1,
                value: sample.value,
                startDate: sample.startTime,
                endDate: endDate,
                metadata: metadata
            )
        )
    }

    private static func isValueValid(_ value: Double, for metric: HealthMetric) -> Bool {
        switch metric {
        case .spo2:
            // HealthKit percent quantities use fractional values, not 0...100.
            return value > 0 && value <= 1
        case .steps, .heartRate, .activeCalories, .totalCalories, .distance, .floors, .bodyTemperature:
            return value > 0
        case .skinTemperature, .ibi, .hrv, .respiratoryRate:
            return value > 0
        }
    }
}

/// A removal request for one previously-derived daily cumulative interval.
/// The id and sync identifier deliberately match the later raw Watch sample
/// that originally identified the derived interval. The iOS adapter may
/// delete only its own object with this exact identifier and quantity type.
public struct AppleHealthCumulativeRemoval: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let quantityType: AppleHealthQuantityType
    public let syncIdentifier: String
    public let revision: Int64

    public init(
        id: UUID,
        quantityType: AppleHealthQuantityType,
        syncIdentifier: String,
        revision: Int64
    ) {
        self.id = id
        self.quantityType = quantityType
        self.syncIdentifier = syncIdentifier
        self.revision = revision
    }
}

/// A normalized cumulative export pass. `samples` are safe new/replacement
/// values; `removals` are intervals which a newer Watch correction made zero
/// or negative and therefore must no longer remain in Apple Health.
public struct AppleHealthCumulativeExportPlan: Equatable, Sendable {
    public let samples: [HealthSample]
    public let removals: [AppleHealthCumulativeRemoval]

    public init(samples: [HealthSample], removals: [AppleHealthCumulativeRemoval]) {
        self.samples = samples
        self.removals = removals
    }
}

/// Converts cumulative daily readings into non-overlapping HealthKit quantity
/// intervals. Wear OS `STEPS_DAILY` and `DISTANCE_DAILY` are snapshots from
/// the beginning of a day, not independent interval measurements. Exporting
/// each raw snapshot would double count. Each derived value therefore uses
/// the delta from the immediately preceding snapshot in the same daily
/// series. The later raw sample's stable UUID identifies the derived interval
/// and the maximum revision lets a corrected baseline replace the interval
/// through HealthKit's sync identifier/version metadata.
public enum AppleHealthCumulativeNormalizer {
    /// Returns both positive values and corrections which invalidate a
    /// previously exported interval. Callers that only need a display/export
    /// candidate list may use `exportableSamples(from:)`, but production
    /// HealthKit writers must consume the full plan so an old positive delta
    /// cannot survive a later Watch correction to zero or below.
    public static func exportPlan(from samples: [HealthSample]) -> AppleHealthCumulativeExportPlan {
        let cumulative = samples.filter {
            ($0.metric == .steps || $0.metric == .distance || $0.metric == .floors) &&
                $0.aggregation == .dailyCumulative
        }
        // `CALORIES_DAILY` includes basal metabolism. It remains an in-app
        // display value and is intentionally omitted before any HealthKit
        // adapter sees it; the mapper also rejects it as a second guard.
        let passthrough = samples.filter {
            $0.metric != .totalCalories &&
                !($0.aggregation == .dailyCumulative &&
                    ($0.metric == .steps || $0.metric == .distance || $0.metric == .floors))
        }

        let grouped = Dictionary(grouping: cumulative, by: DailySeriesKey.init)
        let normalized = grouped.values.map(normalizeDailySeries)
        let sortedSamples = (passthrough + normalized.flatMap(\.samples)).sorted { left, right in
            if left.startTime != right.startTime { return left.startTime < right.startTime }
            return left.id.uuidString < right.id.uuidString
        }
        return AppleHealthCumulativeExportPlan(
            samples: sortedSamples,
            removals: normalized.flatMap(\.removals).sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    public static func exportableSamples(from samples: [HealthSample]) -> [HealthSample] {
        exportPlan(from: samples).samples
    }

    private static func normalizeDailySeries(_ source: [HealthSample]) -> AppleHealthCumulativeExportPlan {
        let ordered = source.sorted { left, right in
            let leftEnd = left.endTime ?? left.startTime
            let rightEnd = right.endTime ?? right.startTime
            if leftEnd != rightEnd { return leftEnd < rightEnd }
            if left.revision != right.revision { return left.revision < right.revision }
            return left.id.uuidString < right.id.uuidString
        }

        var previous: HealthSample?
        var output: [HealthSample] = []
        var removals: [AppleHealthCumulativeRemoval] = []
        for sample in ordered {
            let end = sample.endTime ?? sample.startTime
            guard end >= sample.startTime else {
                // Preserve an invalid input so the mapper can reject it with
                // its ordinary, user-reportable validation error.
                output.append(sample)
                previous = sample
                continue
            }

            let baseline = previous?.value ?? 0
            let delta = sample.value - baseline
            let intervalStart = previous.map { $0.endTime ?? $0.startTime } ?? sample.startTime
            let revision = max(sample.revision, previous?.revision ?? 0)
            if delta > 0, intervalStart <= end {
                output.append(
                    HealthSample(
                        id: sample.id,
                        metric: sample.metric,
                        value: delta,
                        unit: sample.unit,
                        startTime: intervalStart,
                        endTime: end,
                        source: sample.source,
                        quality: sample.quality,
                        revision: revision,
                        aggregation: .interval
                    )
                )
            } else if intervalStart <= end, previous != nil {
                // This exact stable id represented a positive interval on a
                // prior export pass. A correction can make its delta zero or
                // negative; silently omitting it would leave the former
                // quantity in HealthKit and overcount the day. The platform
                // adapter handles this as a narrowly-scoped app-owned delete.
                removals.append(
                    AppleHealthCumulativeRemoval(
                        id: sample.id,
                        quantityType: quantityType(for: sample.metric),
                        syncIdentifier: syncIdentifier(for: sample.id),
                        revision: revision
                    )
                )
            }
            // A reset/decrease emits no negative HealthKit quantity but still
            // becomes the baseline for the next snapshot in this daily series.
            previous = sample
        }
        return AppleHealthCumulativeExportPlan(samples: output, removals: removals)
    }

    private static func quantityType(for metric: HealthMetric) -> AppleHealthQuantityType {
        switch metric {
        case .steps: .stepCount
        case .distance: .distanceWalkingRunning
        case .floors: .flightsClimbed
        default:
            preconditionFailure("Only cumulative step, distance and floor samples reach this path")
        }
    }

    private static func syncIdentifier(for id: UUID) -> String {
        "com.galaxycompanion.health.sample.\(id.uuidString.lowercased())"
    }

    private struct DailySeriesKey: Hashable {
        let metric: HealthMetric
        let unit: HealthUnit
        let source: HealthSampleSource
        let dayStart: Date

        init(_ sample: HealthSample) {
            metric = sample.metric
            unit = sample.unit
            source = sample.source
            // Health Services supplies this start boundary for its daily
            // aggregates. Keeping the precise value avoids making a later
            // iPhone time-zone change alter the stable grouping.
            dayStart = sample.startTime
        }
    }
}
