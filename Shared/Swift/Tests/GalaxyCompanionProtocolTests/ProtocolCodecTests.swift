import Foundation
import XCTest
@testable import GalaxyCompanionProtocol

final class ProtocolCodecTests: XCTestCase {
    func testCapabilitiesAndFrameRoundTrip() throws {
        let capabilities = WatchCapabilities(
            identity: WatchIdentity(
                model: "Galaxy Watch Test",
                wearOSVersion: "5.0",
                firmwareVersion: "test-1"
            ),
            enabled: [.heartRate, .steps, .spo2]
        )

        let payload = try ProtocolCodec.encode(capabilities)
        let frame = ProtocolFrame(
            type: .capabilities,
            sequence: 7,
            payload: payload
        )

        let encodedFrame = try ProtocolCodec.encode(frame)
        let decodedFrame = try ProtocolCodec.decode(ProtocolFrame.self, from: encodedFrame)
        let decodedCapabilities = try ProtocolCodec.decode(
            WatchCapabilities.self,
            from: decodedFrame.payload
        )

        XCTAssertEqual(decodedFrame, frame)
        XCTAssertEqual(decodedCapabilities, capabilities)
        XCTAssertTrue(decodedCapabilities.supports(.heartRate))
        XCTAssertFalse(decodedCapabilities.supports(.nfcHce))
    }

    func testDecodesCapabilitiesPayloadServedByWearGatt() throws {
        let watchPayload = Data(
            #"{"identity":{"model":"GalaxyCompanion Development Watch","wearOSVersion":"Wear OS","firmwareVersion":"0.1.0-debug"},"enabled":["heartRate","steps","calories","distance"],"healthDataMode":"developmentSynthetic"}"#.utf8
        )

        let decoded = try ProtocolCodec.decode(WatchCapabilities.self, from: watchPayload)

        XCTAssertEqual(decoded.identity.model, "GalaxyCompanion Development Watch")
        XCTAssertEqual(decoded.identity.wearOSVersion, "Wear OS")
        XCTAssertEqual(decoded.enabled, [.heartRate, .steps, .calories, .distance])
        XCTAssertEqual(decoded.healthDataMode, .developmentSynthetic)
    }

    func testDecodesGranularAggregationAndMigratesLegacyDailyTotals() throws {
        let intervalPayload = Data(
            #"{"id":"00112233-4455-6677-8899-aabbccddeeff","metric":"steps","value":42,"unit":"count","startTime":1700000000000,"endTime":1700000300000,"source":"wearHealthServices","quality":"measured","revision":4,"aggregation":"interval"}"#.utf8
        )
        let legacyDailyPayload = Data(
            #"{"id":"00112233-4455-6677-8899-aabbccddeee0","metric":"distance","value":120,"unit":"meters","startTime":1700000000000,"endTime":1700000300000,"source":"wearHealthServices","quality":"measured","revision":4}"#.utf8
        )

        let interval = try ProtocolCodec.decode(HealthSample.self, from: intervalPayload)
        let legacyDaily = try ProtocolCodec.decode(HealthSample.self, from: legacyDailyPayload)

        XCTAssertEqual(interval.aggregation, .interval)
        XCTAssertEqual(legacyDaily.aggregation, .dailyCumulative)
    }

    func testGATTHealthSyncPacketsReassembleOutOfOrder() throws {
        let payload = Data(repeating: 0x61, count: 73)
        let rawPackets = try GATTHealthSyncPacketCodec.fragment(
            payload: payload,
            sequence: 42,
            maximumPacketSize: 20
        )
        XCTAssertGreaterThan(rawPackets.count, 1)

        var assembler = GATTHealthSyncPacketAssembler()
        var completedPayload: Data?
        for rawPacket in rawPackets.reversed() {
            completedPayload = try assembler.append(
                GATTHealthSyncPacketCodec.decode(rawPacket)
            ) ?? completedPayload
        }

        XCTAssertEqual(completedPayload, payload)
    }

    func testRejectsIncompatibleGATTPacketVersion() throws {
        XCTAssertThrowsError(try GATTHealthSyncPacketCodec.fragment(
            payload: Data("{}".utf8),
            protocolVersion: 2,
            sequence: 1,
            maximumPacketSize: 20
        )) {
            XCTAssertEqual($0 as? GATTHealthSyncPacketError, .incompatibleProtocolVersion(2))
        }
    }

    func testRequestIdentifierRoundTrips() throws {
        let request = HealthSyncRequest(
            requestID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            afterCursor: 5,
            maximumSampleCount: 20
        )

        XCTAssertEqual(
            try ProtocolCodec.decode(HealthSyncRequest.self, from: ProtocolCodec.encode(request)),
            request
        )
    }

    func testRejectsReservedFlagsAndOversizedFragments() throws {
        var packet = try GATTHealthSyncPacketCodec.fragment(
            payload: Data("{}".utf8),
            sequence: 1,
            maximumPacketSize: 20
        )[0]
        packet[1] = 1

        XCTAssertThrowsError(try GATTHealthSyncPacketCodec.decode(packet)) {
            XCTAssertEqual($0 as? GATTHealthSyncPacketError, .reservedFlagsNonZero(1))
        }

        let excessiveFragmentCount = Data([
            1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 129
        ])
        XCTAssertThrowsError(try GATTHealthSyncPacketCodec.decode(excessiveFragmentCount)) {
            XCTAssertEqual($0 as? GATTHealthSyncPacketError, .invalidFragmentRange)
        }

        XCTAssertThrowsError(try GATTHealthSyncPacketCodec.fragment(
            payload: Data(repeating: 0, count: GATTHealthSyncPacketCodec.maximumReassembledPayloadBytes + 1),
            sequence: 1,
            maximumPacketSize: 20
        )) {
            XCTAssertEqual($0 as? GATTHealthSyncPacketError, .packetTooLarge)
        }
    }

    func testRejectsNegativeSigned63BitSequence() throws {
        XCTAssertThrowsError(try GATTHealthSyncPacketCodec.fragment(
            payload: Data("{}".utf8),
            sequence: -1,
            maximumPacketSize: 20
        )) {
            XCTAssertEqual($0 as? GATTHealthSyncPacketError, .invalidSequence(-1))
        }
    }

}
