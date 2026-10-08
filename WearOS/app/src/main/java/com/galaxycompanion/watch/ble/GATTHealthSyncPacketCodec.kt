package com.galaxycompanion.watch.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Android counterpart of `GATTHealthSyncPacketCodec` in Shared/Swift. It
 * fragments a versioned JSON HealthSyncBatch so every GATT notification fits
 * the connected central's negotiated ATT payload length.
 */
internal object GATTHealthSyncPacketCodec {
    const val headerLength = 14
    const val maximumFragmentCount = 128
    const val maximumFragmentPayloadBytes = 512
    const val maximumReassembledPayloadBytes = maximumFragmentCount * maximumFragmentPayloadBytes

    fun fragment(
        payload: ByteArray,
        protocolVersion: Int,
        sequence: Long,
        maximumPacketSize: Int
    ): List<ByteArray> {
        require(protocolVersion == GalaxyCompanionGattContract.protocolVersion)
        require(sequence >= 0L)
        require(maximumPacketSize > headerLength)
        require(maximumPacketSize <= headerLength + maximumFragmentPayloadBytes)
        require(payload.size <= maximumReassembledPayloadBytes)

        val chunkLength = maximumPacketSize - headerLength
        val fragmentCount = maxOf(1, (payload.size + chunkLength - 1) / chunkLength)
        require(fragmentCount <= maximumFragmentCount)

        return List(fragmentCount) { fragmentIndex ->
            val start = fragmentIndex * chunkLength
            val end = minOf(start + chunkLength, payload.size)
            val packet = ByteBuffer.allocate(headerLength + (end - start))
                .order(ByteOrder.BIG_ENDIAN)
                .put(protocolVersion.toByte())
                .put(0) // Reserved flags.
                .putLong(sequence)
                .putShort(fragmentIndex.toShort())
                .putShort(fragmentCount.toShort())
            if (start < end) {
                packet.put(payload, start, end - start)
            }
            packet.array()
        }
    }
}
