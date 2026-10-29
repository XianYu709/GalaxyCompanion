package com.galaxycompanion.watch.ble

import java.util.UUID

/**
 * Stable identifiers for the app-owned BLE service. They are not Samsung or
 * Galaxy Wearable protocol identifiers and can evolve only through protocol
 * version negotiation.
 */
object GalaxyCompanionGattContract {
    const val protocolVersion: Int = 1

    val serviceUuid: UUID = UUID.fromString("2b0d0001-4f31-4bb2-8f63-891bb1bd0001")
    val capabilitiesCharacteristicUuid: UUID = UUID.fromString("2b0d0002-4f31-4bb2-8f63-891bb1bd0001")
    val syncControlCharacteristicUuid: UUID = UUID.fromString("2b0d0003-4f31-4bb2-8f63-891bb1bd0001")
    val syncDataCharacteristicUuid: UUID = UUID.fromString("2b0d0004-4f31-4bb2-8f63-891bb1bd0001")
    val pairingGateCharacteristicUuid: UUID = UUID.fromString("2b0d0005-4f31-4bb2-8f63-891bb1bd0001")

    val pairingGatePayload: ByteArray = byteArrayOf(0x47, 0x43, 0x50, 0x01, 0x01)
}

