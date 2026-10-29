import XCTest
@testable import GalaxyCompanionHealth
import GalaxyCompanionProtocol

final class SleepAnalysisTests: XCTestCase {
    func testEstimatesConservativeRestPeriodFromRealHeartRateAndGranularActivity() throws {
        let calendar = gmtCalendar
        let now = date("2026-10-10T09:00:00Z")
        let samples = heartRates(hours: [22, 0, 2, 4, 6], calendar: calendar) + [
            activity(
                metric: .steps,
                value: 50,
                start: date("2026-10-10T02:55:00Z"),
                end: date("2026-10-10T03:00:00Z")
            )
        ]

        let result = LocalSleepAnalyzer.analyze(samples: samples, at: now, calendar: calendar)
        guard case .estimated(let session) = result else {
            return XCTFail("Expected a locally-derived estimate, got \(result)")
        }

        XCTAssertEqual(session.startTime, date("2026-10-09T21:45:00Z"))
        XCTAssertEqual(session.endTime, date("2026-10-10T06:15:00Z"))
        XCTAssertEqual(session.timeInBed, 8.5 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(session.estimatedSleepDuration, 8.25 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(session.efficiency, 8.25 / 8.5, accuracy: 0.0001)
        XCTAssertEqual(session.heartRateSampleCount, 5)
        XCTAssertEqual(session.activityIntervalCount, 1)
        XCTAssertEqual(session.analysisVersion, LocalSleepAnalyzer.analysisVersion)
    }

    func testRefusesToTreatDailyStepTotalAsAWithinNightActivitySignal() {
        let calendar = gmtCalendar
        let samples = heartRates(hours: [22, 0, 2, 4, 6], calendar: calendar) + [
            HealthSample(
                metric: .steps,
                value: 4_000,
                unit: .count,
                startTime: date("2026-10-09T00:00:00Z"),
                endTime: date("2026-10-10T06:00:00Z"),
                source: .wearHealthServices,
                quality: .measured,
                aggregation: .dailyCumulative
            )
        ]

        XCTAssertEqual(
            LocalSleepAnalyzer.analyze(
                samples: samples,
                at: date("2026-10-10T09:00:00Z"),
                calendar: calendar
            ),
            .unavailable(.missingGranularActivity)
        )
    }

    func testRefusesSparseOrGappyHeartRateData() {
        let calendar = gmtCalendar
        let sparse = heartRates(hours: [22, 1, 4], calendar: calendar) + [
            activity(
                metric: .distance,
                value: 30,
                start: date("2026-10-10T01:15:00Z"),
                end: date("2026-10-10T01:20:00Z")
            )
        ]
        XCTAssertEqual(
            LocalSleepAnalyzer.analyze(
                samples: sparse,
                at: date("2026-10-10T09:00:00Z"),
                calendar: calendar
            ),
            .unavailable(.insufficientHeartRateSamples(required: 4, actual: 3))
        )

        let gappy = heartRates(hours: [18, 19, 20, 5, 6], calendar: calendar) + [
            activity(
                metric: .steps,
                value: 25,
                start: date("2026-10-10T00:15:00Z"),
                end: date("2026-10-10T00:20:00Z")
            )
        ]
        XCTAssertEqual(
            LocalSleepAnalyzer.analyze(
                samples: gappy,
                at: date("2026-10-10T09:00:00Z"),
                calendar: calendar
            ),
            .unavailable(.heartRateCoverageGap(minutes: 540))
        )
    }

    func testGranularStepsPassThroughHealthKitWithoutCumulativeRenormalization() {
        let delta = HealthSample(
            metric: .steps,
            value: 42,
            unit: .count,
            startTime: date("2026-10-10T00:00:00Z"),
            endTime: date("2026-10-10T00:05:00Z"),
            source: .wearHealthServices,
            quality: .measured,
            aggregation: .interval
        )

        let plan = AppleHealthCumulativeNormalizer.exportPlan(from: [delta])
        XCTAssertEqual(plan.samples, [delta])
        XCTAssertTrue(plan.removals.isEmpty)
    }

    private var gmtCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func heartRates(hours: [Int], calendar: Calendar) -> [HealthSample] {
        hours.map { hour in
            let day = hour >= 18 ? "2026-10-09" : "2026-10-10"
            return HealthSample(
                metric: .heartRate,
                value: 56,
                unit: .beatsPerMinute,
                startTime: date("\(day)T\(String(format: "%02d", hour)):00:00Z"),
                source: .wearHealthServices,
                quality: .measured,
                aggregation: .instantaneous
            )
        }
    }

    private func activity(
        metric: HealthMetric,
        value: Double,
        start: Date,
        end: Date
    ) -> HealthSample {
        HealthSample(
            metric: metric,
            value: value,
            unit: metric == .steps ? .count : .meters,
            startTime: start,
            endTime: end,
            source: .wearHealthServices,
            quality: .measured,
            aggregation: .interval
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
