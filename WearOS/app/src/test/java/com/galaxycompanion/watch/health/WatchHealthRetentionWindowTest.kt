package com.galaxycompanion.watch.health

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchHealthRetentionWindowTest {
    @Test
    fun normalCorrectionDoesNotCreateRetentionGapForFreshPhone() {
        // A revision replaces cursor 1 with cursor 2 but does not evict any
        // row. A new phone can still recover the current sample from cursor 0.
        val result = WatchHealthRetentionWindow.retain(
            samples = listOf(sample(cursor = 2)),
            maximumRetainedSamples = 2_000,
            previousEvictedThroughCursor = 0
        )

        assertEquals(0L, result.evictedThroughCursor)
        assertFalse(WatchHealthRetentionWindow.requiresRecovery(0, result.evictedThroughCursor))
    }

    @Test
    fun actualCapacityEvictionRequiresRecoveryForStaleCursor() {
        val result = WatchHealthRetentionWindow.retain(
            samples = listOf(sample(cursor = 1), sample(cursor = 2), sample(cursor = 3)),
            maximumRetainedSamples = 2,
            previousEvictedThroughCursor = 0
        )

        assertEquals(listOf(2L, 3L), result.retained.map(StoredWatchHealthSample::cursor))
        assertEquals(1L, result.evictedThroughCursor)
        assertTrue(WatchHealthRetentionWindow.requiresRecovery(0, result.evictedThroughCursor))
    }

    @Test
    fun cursorAtEvictionWatermarkCanResume() {
        val result = WatchHealthRetentionWindow.retain(
            samples = listOf(sample(cursor = 2), sample(cursor = 3)),
            maximumRetainedSamples = 2,
            previousEvictedThroughCursor = 1
        )

        assertFalse(WatchHealthRetentionWindow.requiresRecovery(1, result.evictedThroughCursor))
    }

    private fun sample(cursor: Long) = StoredWatchHealthSample(
        id = "00000000-0000-0000-0000-${cursor.toString().padStart(12, '0')}",
        metric = "steps",
        value = cursor.toDouble(),
        unit = "count",
        startTimeMillis = cursor,
        endTimeMillis = cursor,
        cursor = cursor
    )
}
