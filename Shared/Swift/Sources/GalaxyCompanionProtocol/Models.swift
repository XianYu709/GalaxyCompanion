import Foundation

public enum WatchCapability: String, CaseIterable, Codable, Sendable {
    case heartRate
    case ibi
    case steps
    case calories
    case distance
    case floors
    case spo2
    case skinTemperature
    case respiratoryRate
    case ppg
    case accelerometer
    case eda
    case bia
    case mfBia
    case ecg
    case nfcReader
    case nfcHce
}

public struct WatchIdentity: Codable, Equatable, Sendable {
    public let model: String
    public let wearOSVersion: String
    public let firmwareVersion: String

    public init(model: String, wearOSVersion: String, firmwareVersion: String) {
        self.model = model
        self.wearOSVersion = wearOSVersion
        self.firmwareVersion = firmwareVersion
    }
}

public struct WatchCapabilities: Codable, Equatable, Sendable {
    public let identity: WatchIdentity
    public let enabled: Set<WatchCapability>
    /// Describes whether the Watch currently offers health data that could
    /// ever be considered outside a development environment. This is a
    /// disclosure label, not an authentication claim.
    public let healthDataMode: HealthDataMode

    public init(
        identity: WatchIdentity,
        enabled: Set<WatchCapability>,
        healthDataMode: HealthDataMode = .unavailable
    ) {
        self.identity = identity
        self.enabled = enabled
        self.healthDataMode = healthDataMode
    }

    public func supports(_ capability: WatchCapability) -> Bool {
        enabled.contains(capability)
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case enabled
        case healthDataMode
    }

    /// Missing disclosure metadata is deliberately treated as unavailable so
    /// older peers can never be mistaken for authenticated health sources.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(WatchIdentity.self, forKey: .identity)
        enabled = try container.decode(Set<WatchCapability>.self, forKey: .enabled)
        healthDataMode = try container.decodeIfPresent(HealthDataMode.self, forKey: .healthDataMode)
            ?? .unavailable
    }
}

/// Transport disclosure for health values. `authenticatedMeasurement` is
/// reserved until an authenticated pairing protocol is implemented and
/// verified; this repository does not currently produce it.
public enum HealthDataMode: String, Codable, Equatable, Sendable {
    case unavailable
    case developmentSynthetic
    case authenticatedMeasurement
}

public enum HealthMetric: String, CaseIterable, Codable, Sendable {
    case steps
    case heartRate
    case ibi
    case hrv
    case activeCalories
    case distance
    case floors
    case spo2
    case skinTemperature
    /// A calibrated body-temperature measurement. This is intentionally
    /// distinct from `skinTemperature`, which must not be exported as body
    /// temperature without a separately validated provider contract.
    case bodyTemperature
    case respiratoryRate
}

public enum HealthUnit: String, Codable, Sendable {
    case count
    case beatsPerMinute
    case milliseconds
    case kilocalories
    case meters
    case percent
    case celsius
    case breathsPerMinute
}

public enum HealthSampleSource: String, Codable, Sendable {
    case wearHealthServices
    case samsungHealthSensor
    case derived
    /// Deterministic development data. It must never be represented as a
    /// measurement obtained from a physical sensor.
    case demo
}

public enum SampleQuality: String, Codable, Sendable {
    case unknown
    case estimated
    case measured
    case unreliable
}

public struct HealthSample: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let metric: HealthMetric
    public let value: Double
    public let unit: HealthUnit
    public let startTime: Date
    public let endTime: Date?
    public let source: HealthSampleSource
    public let quality: SampleQuality

    public init(
        id: UUID = UUID(),
        metric: HealthMetric,
        value: Double,
        unit: HealthUnit,
        startTime: Date,
        endTime: Date? = nil,
        source: HealthSampleSource,
        quality: SampleQuality
    ) {
        self.id = id
        self.metric = metric
        self.value = value
        self.unit = unit
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.quality = quality
    }
}

public enum ProtocolMessageType: String, Codable, Sendable {
    case hello
    case capabilities
    case timeSync
    case syncRequest
    case syncBatch
    case syncAcknowledgement
    case syncDone
    case ping
    case error
}

public struct ProtocolFrame: Codable, Equatable, Sendable {
    public let version: UInt16
    public let type: ProtocolMessageType
    /// Cross-platform counter: signed, non-negative 63-bit integer.
    public let sequence: Int64
    /// Cross-platform cursor: signed, non-negative 63-bit integer.
    public let cursor: Int64?
    public let payload: Data

    public init(
        version: UInt16 = 1,
        type: ProtocolMessageType,
        sequence: Int64,
        cursor: Int64? = nil,
        payload: Data
    ) {
        self.version = version
        self.type = type
        self.sequence = sequence
        self.cursor = cursor
        self.payload = payload
    }
}

public enum ProtocolCodec {
    public static let currentVersion: UInt16 = 1

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// Value written to the app-owned GATT sync-control characteristic. The
/// characteristic UUID conveys the message kind; this value carries the
/// protocol version and the requested incremental cursor.
public struct HealthSyncRequest: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    /// Opaque correlation value created by the requester and echoed verbatim
    /// by the batch. It binds a response to one outstanding request.
    public let requestID: UUID
    /// Signed, non-negative 63-bit cursor shared with Kotlin `Long`.
    public let afterCursor: Int64
    public let maximumSampleCount: UInt16

    public init(
        protocolVersion: UInt16 = ProtocolCodec.currentVersion,
        requestID: UUID,
        afterCursor: Int64,
        maximumSampleCount: UInt16
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.afterCursor = afterCursor
        self.maximumSampleCount = maximumSampleCount
    }
}

/// A compact GATT-level envelope for one fragment of a JSON sync batch.
///
/// BLE notifications may be smaller than a complete JSON health batch. The
/// reassembled `payload` is always the JSON encoding of `HealthSyncBatch`;
/// this envelope only makes that JSON safe to transfer over ATT. Its fixed
/// header is: version (1 byte), flags (1 byte, reserved), sequence (8 bytes,
/// big-endian), fragment index (2 bytes), fragment count (2 bytes).
public struct GATTHealthSyncPacket: Equatable, Sendable {
    public let protocolVersion: UInt16
    /// Signed, non-negative 63-bit sequence shared with Kotlin `Long`.
    public let sequence: Int64
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let payload: Data

    public init(
        protocolVersion: UInt16,
        sequence: Int64,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        payload: Data
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payload = payload
    }
}

public enum GATTHealthSyncPacketError: Error, Equatable, Sendable {
    case packetTooSmall
    case packetVersionOutOfRange(UInt16)
    case tooManyFragments
    case packetTooLarge
    case malformedPacket
    case invalidFragmentRange
    case reservedFlagsNonZero(UInt8)
    case invalidSequence(Int64)
    case incompatibleProtocolVersion(UInt16)
    case unexpectedTransfer
}

public enum GATTHealthSyncPacketCodec {
    public static let headerLength = 14
    public static let maximumFragmentCount = 128
    public static let maximumFragmentPayloadBytes = 512
    public static let maximumReassembledPayloadBytes = maximumFragmentCount * maximumFragmentPayloadBytes

    /// Splits a JSON payload into ATT-safe values. `maximumPacketSize` is the
    /// available GATT attribute value length (usually negotiated MTU minus 3).
    public static func fragment(
        payload: Data,
        protocolVersion: UInt16 = ProtocolCodec.currentVersion,
        sequence: Int64,
        maximumPacketSize: Int
    ) throws -> [Data] {
        guard protocolVersion == ProtocolCodec.currentVersion else {
            throw GATTHealthSyncPacketError.incompatibleProtocolVersion(protocolVersion)
        }
        guard sequence >= 0 else {
            throw GATTHealthSyncPacketError.invalidSequence(sequence)
        }
        guard maximumPacketSize > headerLength else {
            throw GATTHealthSyncPacketError.packetTooSmall
        }

        guard maximumPacketSize <= headerLength + maximumFragmentPayloadBytes else {
            throw GATTHealthSyncPacketError.packetTooLarge
        }
        guard payload.count <= maximumReassembledPayloadBytes else {
            throw GATTHealthSyncPacketError.packetTooLarge
        }

        let chunkLength = maximumPacketSize - headerLength
        let fragmentCount = max(1, Int(ceil(Double(payload.count) / Double(chunkLength))))
        guard fragmentCount <= maximumFragmentCount else {
            throw GATTHealthSyncPacketError.tooManyFragments
        }

        return (0..<fragmentCount).map { index in
            let start = index * chunkLength
            let end = min(start + chunkLength, payload.count)
            let chunk = start < end ? payload.subdata(in: start..<end) : Data()
            var packet = Data()
            packet.reserveCapacity(headerLength + chunk.count)
            packet.append(UInt8(protocolVersion))
            packet.append(0) // Reserved flags.
            let wireSequence = UInt64(bitPattern: sequence)
            for shift in stride(from: 56, through: 0, by: -8) {
                packet.append(UInt8(truncatingIfNeeded: wireSequence >> UInt64(shift)))
            }
            packet.append(UInt8(truncatingIfNeeded: UInt16(index) >> 8))
            packet.append(UInt8(truncatingIfNeeded: index))
            packet.append(UInt8(truncatingIfNeeded: UInt16(fragmentCount) >> 8))
            packet.append(UInt8(truncatingIfNeeded: fragmentCount))
            packet.append(chunk)
            return packet
        }
    }

    public static func decode(_ data: Data) throws -> GATTHealthSyncPacket {
        guard data.count >= headerLength else {
            throw GATTHealthSyncPacketError.malformedPacket
        }
        guard data.count <= headerLength + maximumFragmentPayloadBytes else {
            throw GATTHealthSyncPacketError.packetTooLarge
        }

        let bytes = [UInt8](data)
        let protocolVersion = UInt16(bytes[0])
        guard protocolVersion == ProtocolCodec.currentVersion else {
            throw GATTHealthSyncPacketError.incompatibleProtocolVersion(protocolVersion)
        }
        guard bytes[1] == 0 else {
            throw GATTHealthSyncPacketError.reservedFlagsNonZero(bytes[1])
        }
        var wireSequence: UInt64 = 0
        for byte in bytes[2..<10] {
            wireSequence = (wireSequence << 8) | UInt64(byte)
        }
        let sequence = Int64(bitPattern: wireSequence)
        guard sequence >= 0 else {
            throw GATTHealthSyncPacketError.invalidSequence(sequence)
        }
        let fragmentIndex = (UInt16(bytes[10]) << 8) | UInt16(bytes[11])
        let fragmentCount = (UInt16(bytes[12]) << 8) | UInt16(bytes[13])
        guard fragmentCount > 0,
                fragmentCount <= UInt16(maximumFragmentCount),
                fragmentIndex < fragmentCount else {
            throw GATTHealthSyncPacketError.invalidFragmentRange
        }

        return GATTHealthSyncPacket(
            protocolVersion: protocolVersion,
            sequence: sequence,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payload: Data(bytes.dropFirst(headerLength))
        )
    }
}

/// Reassembles one ordered-or-unordered GATT transfer and rejects a different
/// transfer before the current one is complete.
public struct GATTHealthSyncPacketAssembler: Sendable {
    private var activeProtocolVersion: UInt16?
    private var activeSequence: Int64?
    private var expectedFragmentCount: UInt16?
    private var fragments: [UInt16: Data] = [:]
    private var accumulatedPayloadByteCount = 0

    public init() {}

    public mutating func reset() {
        activeProtocolVersion = nil
        activeSequence = nil
        expectedFragmentCount = nil
        fragments.removeAll()
        accumulatedPayloadByteCount = 0
    }

    public mutating func append(_ packet: GATTHealthSyncPacket) throws -> Data? {
        guard packet.protocolVersion == ProtocolCodec.currentVersion else {
            throw GATTHealthSyncPacketError.incompatibleProtocolVersion(packet.protocolVersion)
        }
        guard packet.sequence >= 0 else {
            throw GATTHealthSyncPacketError.invalidSequence(packet.sequence)
        }
        guard packet.fragmentCount > 0,
                packet.fragmentCount <= UInt16(GATTHealthSyncPacketCodec.maximumFragmentCount),
                packet.fragmentIndex < packet.fragmentCount else {
            throw GATTHealthSyncPacketError.invalidFragmentRange
        }
        guard packet.payload.count <= GATTHealthSyncPacketCodec.maximumFragmentPayloadBytes else {
            throw GATTHealthSyncPacketError.packetTooLarge
        }

        if let activeSequence {
            guard activeSequence == packet.sequence,
                    activeProtocolVersion == packet.protocolVersion,
                    expectedFragmentCount == packet.fragmentCount else {
                throw GATTHealthSyncPacketError.unexpectedTransfer
            }
        } else {
            activeSequence = packet.sequence
            activeProtocolVersion = packet.protocolVersion
            expectedFragmentCount = packet.fragmentCount
        }

        if let existing = fragments[packet.fragmentIndex] {
            accumulatedPayloadByteCount -= existing.count
        }
        accumulatedPayloadByteCount += packet.payload.count
        guard accumulatedPayloadByteCount <= GATTHealthSyncPacketCodec.maximumReassembledPayloadBytes else {
            throw GATTHealthSyncPacketError.packetTooLarge
        }
        fragments[packet.fragmentIndex] = packet.payload
        guard fragments.count == Int(packet.fragmentCount) else { return nil }

        var payload = Data()
        for index in UInt16(0)..<packet.fragmentCount {
            guard let fragment = fragments[index] else {
                throw GATTHealthSyncPacketError.malformedPacket
            }
            payload.append(fragment)
        }
        reset()
        return payload
    }
}
