package com.galaxycompanion.watch.ble

import java.util.UUID

/**
 * Identifiers for the app-owned BLE service. They are not Samsung or Galaxy
 * Wearable protocol identifiers. Service revision 7 uses paced ATT
 * notifications for manual-history pages. On the Watch6/iPhone link an ATT
 * indication can fail even after a valid subscription because the iPhone
 * does not return the lower-level confirmation. The protocol is still
 * recoverable: an incomplete page never advances the iPhone cursor, so its
 * next manual pull requests the same page. A fresh service UUID prevents a
 * bonded iPhone from retaining the revision-6 indication property cache.
 */
object GalaxyCompanionGattContract {
    const val protocolVersion: Int = 1

    val serviceUuid: UUID = UUID.fromString("2b0d0007-4f31-4bb2-8f63-891bb1bd0001")
    val capabilitiesCharacteristicUuid: UUID = UUID.fromString("2b0d0002-4f31-4bb2-8f63-891bb1bd0001")
    val syncControlCharacteristicUuid: UUID = UUID.fromString("2b0d0003-4f31-4bb2-8f63-891bb1bd0001")
    val syncDataCharacteristicUuid: UUID = UUID.fromString("2b0d0004-4f31-4bb2-8f63-891bb1bd0001")
    val pairingGateCharacteristicUuid: UUID = UUID.fromString("2b0d0005-4f31-4bb2-8f63-891bb1bd0001")

    val pairingGatePayload: ByteArray = byteArrayOf(0x47, 0x43, 0x50, 0x01, 0x01)
}

