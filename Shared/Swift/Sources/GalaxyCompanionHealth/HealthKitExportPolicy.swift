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
            syncVersion: 1,
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
        case .steps, .heartRate, .activeCalories, .distance, .floors, .bodyTemperature:
            return value > 0
        case .skinTemperature, .ibi, .hrv, .respiratoryRate:
            return value > 0
        }
    }
}
