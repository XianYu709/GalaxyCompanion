import XCTest
@testable import GalaxyCompanionHealth
import GalaxyCompanionProtocol

final class HealthKitExportPolicyTests: XCTestCase {
    func testMapsOnlyExplicitlySupportedQuantitiesWithStableMetadata() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HealthSample(
            id: id,
            metric: .heartRate,
            value: 72,
            unit: .beatsPerMinute,
            startTime: start,
            source: .wearHealthServices,
            quality: .measured
        )

        let payload = try XCTUnwrap(AppleHealthSampleMapper.map(sample).successValue)

        XCTAssertEqual(payload.quantityType, .heartRate)
        XCTAssertEqual(payload.unit, .countPerMinute)
        XCTAssertEqual(payload.metadata.syncIdentifier, "com.galaxycompanion.health.sample.00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertEqual(payload.metadata.syncVersion, 1)
        XCTAssertEqual(payload.metadata.externalUUID, "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertEqual(payload.metadata.source, "GalaxyCompanion.wearHealthServices")
    }

    func testMapsAllSupportedMetricsAndRejectsEverythingElse() throws {
        let cases: [(HealthMetric, Double, HealthUnit, AppleHealthQuantityType)] = [
            (.steps, 5_000, .count, .stepCount),
            (.heartRate, 70, .beatsPerMinute, .heartRate),
            (.activeCalories, 250, .kilocalories, .activeEnergyBurned),
            (.distance, 3_200, .meters, .distanceWalkingRunning),
            (.floors, 8, .count, .flightsClimbed),
            (.spo2, 0.97, .percent, .oxygenSaturation),
            (.bodyTemperature, 36.6, .celsius, .bodyTemperature)
        ]

        for (metric, value, unit, expectedType) in cases {
            let sample = HealthSample(
                metric: metric,
                value: value,
                unit: unit,
                startTime: Date(),
                source: .wearHealthServices,
                quality: .measured
            )
            let payload = try XCTUnwrap(AppleHealthSampleMapper.map(sample).successValue)
            XCTAssertEqual(payload.quantityType, expectedType, "\(metric)")
        }

        let skinTemperature = HealthSample(
            metric: .skinTemperature,
            value: 34,
            unit: .celsius,
            startTime: Date(),
            source: .wearHealthServices,
            quality: .measured
        )
        XCTAssertEqual(
            AppleHealthSampleMapper.map(skinTemperature).failureValue,
            .skinTemperatureIsNotBodyTemperature
        )
    }

    func testRejectsDevelopmentAndInvalidPercentValuesBeforeAnyStoreCanBeCalled() {
        let demo = HealthSample(
            metric: .steps,
            value: 1,
            unit: .count,
            startTime: Date(),
            source: .demo,
            quality: .measured
        )
        XCTAssertEqual(
            AppleHealthSampleMapper.map(demo).failureValue,
            .developmentSampleRejected
        )

        let invalidSpo2 = HealthSample(
            metric: .spo2,
            value: 97,
            unit: .percent,
            startTime: Date(),
            source: .wearHealthServices,
            quality: .measured
        )
        XCTAssertEqual(
            AppleHealthSampleMapper.map(invalidSpo2).failureValue,
            .invalidValue(metric: .spo2)
        )
    }
}

private extension Result where Failure == AppleHealthSampleMappingError {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failureValue: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
