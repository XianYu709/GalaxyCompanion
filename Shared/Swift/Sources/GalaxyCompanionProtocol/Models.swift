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

    public init(identity: WatchIdentity, enabled: Set<WatchCapability>) {
        self.identity = identity
        self.enabled = enabled
    }

    public func supports(_ capability: WatchCapability) -> Bool {
        enabled.contains(capability)
    }
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
    public let sequence: UInt64
    public let cursor: UInt64?
    public let payload: Data

    public init(
        version: UInt16 = 1,
        type: ProtocolMessageType,
        sequence: UInt64,
        cursor: UInt64? = nil,
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

