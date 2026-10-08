import Foundation
#if canImport(GalaxyCompanionProtocol)
import GalaxyCompanionProtocol
#endif
#if canImport(GalaxyCompanionSync)
import GalaxyCompanionSync
#endif

public actor FakeWatchSyncSource: WatchHealthSyncSource {
    private let advertisedCapabilities: WatchCapabilities
    private var samples: [HealthSample]

    public init(capabilities: WatchCapabilities, samples: [HealthSample] = []) {
        self.advertisedCapabilities = capabilities
        self.samples = samples
    }

    public func capabilities() -> WatchCapabilities {
        advertisedCapabilities
    }

    public func append(_ additionalSamples: [HealthSample]) {
        samples.append(contentsOf: additionalSamples)
    }

    public func nextBatch(after cursor: Int64, maximumSampleCount: Int) -> HealthSyncBatch {
        let startIndex = cursor >= Int64(samples.count) ? samples.count : Int(cursor)
        let endIndex = min(startIndex + maximumSampleCount, samples.count)
        let nextSamples = Array(samples[startIndex..<endIndex])

        return HealthSyncBatch(
            sequence: cursor == Int64.max ? Int64.max : cursor + 1,
            nextCursor: Int64(endIndex),
            samples: nextSamples
        )
    }
}
