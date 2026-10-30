package com.galaxycompanion.watch.health

import org.junit.Assert.assertEquals
import org.junit.Test

class StoredWatchHealthSampleTest {
    @Test
    fun floorSamplesHaveAnExplicitProtocolRepresentation() {
        val sample = StoredWatchHealthSample(
            id = "00000000-0000-0000-0000-000000000001",
            metric = "floors",
            value = 4.0,
            unit = "count",
            startTimeMillis = 1_000L,
            endTimeMillis = 2_000L,
            aggregation = "dailyCumulative",
            cursor = 9L
        )

        assertEquals("floors", sample.protocolMetric())
    }
}
