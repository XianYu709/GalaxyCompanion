import XCTest
@testable import GalaxyCompanionHealth
import GalaxyCompanionProtocol

final class HealthKitExportPolicyTests: XCTestCase {
    func testCurrentAuthorizationRequestUsesOnlyCollectedSafeMetrics() {
        XCTAssertEqual(
            AppleHealthSampleMapper.authorizationQuantityTypes,
            [.stepCount, .heartRate, .distanceWalkingRunning, .flightsClimbed]
        )
    }

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

    func testUsesWatchRevisionAsHealthKitSyncVersion() throws {
        let sample = HealthSample(
            metric: .heartRate,
            value: 72,
            unit: .beatsPerMinute,
            startTime: Date(),
            source: .wearHealthServices,
            quality: .measured,
            revision: 7
        )

        let payload = try XCTUnwrap(AppleHealthSampleMapper.map(sample).successValue)

        XCTAssertEqual(payload.metadata.syncVersion, 7)
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

        let totalCalories = HealthSample(
            metric: .totalCalories,
            value: 80,
            unit: .kilocalories,
            startTime: Date(),
            source: .wearHealthServices,
            quality: .measured
        )
        XCTAssertEqual(
            AppleHealthSampleMapper.map(totalCalories).failureValue,
            .unsupportedMetric(.totalCalories)
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

    func testNormalizesDailyCumulativeStepsIntoNonOverlappingIntervals() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let firstEnd = dayStart.addingTimeInterval(60)
        let secondEnd = dayStart.addingTimeInterval(120)
        let first = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            metric: .steps,
            value: 120,
            unit: .count,
            startTime: dayStart,
            endTime: firstEnd,
            source: .wearHealthServices,
            quality: .measured,
            revision: 3
        )
        let second = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            metric: .steps,
            value: 155,
            unit: .count,
            startTime: dayStart,
            endTime: secondEnd,
            source: .wearHealthServices,
            quality: .measured,
            revision: 4
        )

        let normalized = AppleHealthCumulativeNormalizer.exportableSamples(from: [second, first])

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].id, first.id)
        XCTAssertEqual(normalized[0].value, 120)
        XCTAssertEqual(normalized[0].startTime, dayStart)
        XCTAssertEqual(normalized[0].endTime, firstEnd)
        XCTAssertEqual(normalized[1].id, second.id)
        XCTAssertEqual(normalized[1].value, 35)
        XCTAssertEqual(normalized[1].startTime, firstEnd)
        XCTAssertEqual(normalized[1].endTime, secondEnd)
        XCTAssertEqual(normalized[1].revision, 4)
    }

    func testCumulativeCorrectionBumpsDerivedIntervalSyncVersion() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_100_000)
        let first = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            metric: .distance,
            value: 400,
            unit: .meters,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(60),
            source: .wearHealthServices,
            quality: .measured,
            revision: 9
        )
        let later = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
            metric: .distance,
            value: 650,
            unit: .meters,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(120),
            source: .wearHealthServices,
            quality: .measured,
            revision: 7
        )

        let normalized = AppleHealthCumulativeNormalizer.exportableSamples(from: [first, later])
        let payload = try XCTUnwrap(AppleHealthSampleMapper.map(normalized[1]).successValue)

        XCTAssertEqual(normalized[1].value, 250)
        XCTAssertEqual(payload.metadata.syncVersion, 9)
    }

    func testNormalizesDailyFloorsBeforeHealthKitExport() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_150_000)
        let first = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000115")!,
            metric: .floors,
            value: 3,
            unit: .count,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(60),
            source: .wearHealthServices,
            quality: .measured,
            aggregation: .dailyCumulative
        )
        let later = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000116")!,
            metric: .floors,
            value: 5,
            unit: .count,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(120),
            source: .wearHealthServices,
            quality: .measured,
            aggregation: .dailyCumulative
        )

        let normalized = AppleHealthCumulativeNormalizer.exportableSamples(from: [later, first])

        XCTAssertEqual(normalized.map(\.value), [3, 2])
        XCTAssertEqual(
            try XCTUnwrap(AppleHealthSampleMapper.map(normalized.last!).successValue).quantityType,
            .flightsClimbed
        )
    }

    func testCumulativeDownwardCorrectionCreatesDurableRemovalForPreviouslyExportedInterval() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_200_000)
        let first = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!,
            metric: .steps,
            value: 100,
            unit: .count,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(60),
            source: .wearHealthServices,
            quality: .measured,
            revision: 1
        )
        let intervalID = UUID(uuidString: "00000000-0000-0000-0000-000000000122")!
        let exportedLater = HealthSample(
            id: intervalID,
            metric: .steps,
            value: 150,
            unit: .count,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(120),
            source: .wearHealthServices,
            quality: .measured,
            revision: 1
        )

        let initiallyExported = AppleHealthCumulativeNormalizer.exportPlan(from: [first, exportedLater])
        XCTAssertEqual(initiallyExported.samples.map(\.value).reduce(0, +), 150)
        XCTAssertTrue(initiallyExported.removals.isEmpty)
        XCTAssertEqual(initiallyExported.samples.last?.id, intervalID)
        XCTAssertEqual(initiallyExported.samples.last?.value, 50)

        let correctedLater = HealthSample(
            id: intervalID,
            metric: .steps,
            value: 90,
            unit: .count,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(120),
            source: .wearHealthServices,
            quality: .measured,
            revision: 2
        )
        let correctedPlan = AppleHealthCumulativeNormalizer.exportPlan(from: [first, correctedLater])

        // The former +50 interval must not remain in Apple Health. The
        // iOS adapter deletes this exact app-owned sync identifier before it
        // removes its durable ledger entry, making any failed delete retryable.
        XCTAssertFalse(correctedPlan.samples.contains { $0.id == intervalID })
        XCTAssertEqual(
            correctedPlan.removals,
            [
                AppleHealthCumulativeRemoval(
                    id: intervalID,
                    quantityType: .stepCount,
                    syncIdentifier: "com.galaxycompanion.health.sample.00000000-0000-0000-0000-000000000122",
                    revision: 2
                )
            ]
        )
        XCTAssertEqual(correctedPlan.samples.map(\.value).reduce(0, +), 100)
    }

    func testCumulativePositiveCorrectionKeepsStableSyncIdentifierAndAdvancesVersion() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_300_000)
        let first = HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000131")!,
            metric: .distance,
            value: 100,
            unit: .meters,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(60),
            source: .wearHealthServices,
            quality: .measured,
            revision: 1
        )
        let intervalID = UUID(uuidString: "00000000-0000-0000-0000-000000000132")!
        let initiallyExported = HealthSample(
            id: intervalID,
            metric: .distance,
            value: 150,
            unit: .meters,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(120),
            source: .wearHealthServices,
            quality: .measured,
            revision: 2
        )
        let corrected = HealthSample(
            id: intervalID,
            metric: .distance,
            value: 160,
            unit: .meters,
            startTime: dayStart,
            endTime: dayStart.addingTimeInterval(120),
            source: .wearHealthServices,
            quality: .measured,
            revision: 3
        )

        let firstPayload = try XCTUnwrap(
            AppleHealthSampleMapper.map(
                AppleHealthCumulativeNormalizer.exportPlan(from: [first, initiallyExported]).samples.last!
            ).successValue
        )
        let correctedPayload = try XCTUnwrap(
            AppleHealthSampleMapper.map(
                AppleHealthCumulativeNormalizer.exportPlan(from: [first, corrected]).samples.last!
            ).successValue
        )

        XCTAssertEqual(firstPayload.value, 50)
        XCTAssertEqual(correctedPayload.value, 60)
        XCTAssertEqual(correctedPayload.metadata.syncIdentifier, firstPayload.metadata.syncIdentifier)
        XCTAssertGreaterThan(correctedPayload.metadata.syncVersion, firstPayload.metadata.syncVersion)
    }

    func testLeavesDailyTotalCaloriesInsideTheApp() {
        let totalCalories = HealthSample(
            metric: .totalCalories,
            value: 1_850,
            unit: .kilocalories,
            startTime: Date(),
            source: .wearHealthServices,
            quality: .measured
        )

        XCTAssertTrue(AppleHealthCumulativeNormalizer.exportableSamples(from: [totalCalories]).isEmpty)
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
