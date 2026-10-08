import Foundation
import GalaxyCompanionProtocol
import GalaxyCompanionSync

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

    public func nextBatch(after cursor: UInt64, maximumSampleCount: Int) -> HealthSyncBatch {
        let startIndex = min(Int(cursor), samples.count)
        let endIndex = min(startIndex + maximumSampleCount, samples.count)
        let nextSamples = Array(samples[startIndex..<endIndex])

        return HealthSyncBatch(
            sequence: cursor + 1,
            nextCursor: UInt64(endIndex),
            samples: nextSamples
        )
    }
}

