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
}

