package com.galaxycompanion.watch.ble

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Explicitly synthetic Watch-side samples used to exercise the Phase 2 GATT
 * transport before Health Services collection is implemented. The first launch
 * writes deterministic fixtures to private SharedPreferences; later launches
 * read exactly those same values back. Nothing in this store accesses a sensor.
 */
internal class WatchDemoHealthSampleStore(context: Context) {
    private val preferences: SharedPreferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE
    )

    fun nextBatch(
        requestId: String,
        afterCursor: Long,
        requestedMaximumSampleCount: Int
    ): WatchDemoHealthSyncBatch? {
        require(afterCursor >= 0L)
        val samples = loadOrCreateSamples() ?: return null
        val maximumSampleCount = requestedMaximumSampleCount.coerceIn(1, MAXIMUM_SAMPLE_COUNT)
        val startIndex = afterCursor.coerceIn(0L, samples.size.toLong()).toInt()
        val endIndex = minOf(startIndex + maximumSampleCount, samples.size)
        val nextCursor = if (afterCursor > samples.size.toLong()) afterCursor else endIndex.toLong()
        val sequence = if (afterCursor == Long.MAX_VALUE) Long.MAX_VALUE else afterCursor + 1

        return WatchDemoHealthSyncBatch(
            protocolVersion = GalaxyCompanionGattContract.protocolVersion,
            requestId = requestId,
            sequence = sequence,
            nextCursor = nextCursor,
            samples = samples.subList(startIndex, endIndex)
        )
    }

    fun encodeBatch(batch: WatchDemoHealthSyncBatch): ByteArray {
        val samples = JSONArray()
        batch.samples.forEach { sample ->
            samples.put(
                JSONObject()
                    .put("id", sample.id)
                    .put("metric", sample.metric)
                    .put("value", sample.value)
                    .put("unit", sample.unit)
                    .put("startTime", sample.startTimeMilliseconds)
                    .put("source", "demo")
                    .put("quality", sample.quality)
            )
        }
        return JSONObject()
            .put("protocolVersion", batch.protocolVersion)
            .put("requestID", batch.requestId)
            .put("sequence", batch.sequence)
            .put("nextCursor", batch.nextCursor)
            .put("samples", samples)
            .toString()
            .encodeToByteArray()
    }

    private fun loadOrCreateSamples(): List<WatchDemoHealthSample>? {
        val storedValue = preferences.getString(SAMPLES_KEY, null)
        storedValue?.let { encoded ->
            decodeSamples(encoded)?.let { return it }
        }

        val samples = DEMO_SAMPLES
        // commit() is deliberate: this development fixture becomes durable
        // before we report it through BLE, including across app process death.
        return samples.takeIf {
            preferences.edit().putString(SAMPLES_KEY, encodeSamples(samples)).commit()
        }
    }

    private fun encodeSamples(samples: List<WatchDemoHealthSample>): String {
        val array = JSONArray()
        samples.forEach { sample ->
            array.put(
                JSONObject()
                    .put("id", sample.id)
                    .put("metric", sample.metric)
                    .put("value", sample.value)
                    .put("unit", sample.unit)
                    .put("startTime", sample.startTimeMilliseconds)
                    .put("quality", sample.quality)
            )
        }
        return array.toString()
    }

    private fun decodeSamples(encoded: String): List<WatchDemoHealthSample>? = try {
        val array = JSONArray(encoded)
        buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(
                    WatchDemoHealthSample(
                        id = item.getString("id"),
                        metric = item.getString("metric"),
                        value = item.getDouble("value"),
                        unit = item.getString("unit"),
                        startTimeMilliseconds = item.getLong("startTime"),
                        quality = item.getString("quality")
                    )
                )
            }
        }.takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    private companion object {
        const val PREFERENCES_NAME = "galaxy_companion_demo_health"
        const val SAMPLES_KEY = "version_1_samples"
        const val MAXIMUM_SAMPLE_COUNT = 20

        val DEMO_SAMPLES = listOf(
            WatchDemoHealthSample(
                id = "00000000-0000-0000-0000-000000000001",
                metric = "steps",
                value = 3_842.0,
                unit = "count",
                startTimeMilliseconds = 1_728_000_000_000,
                quality = "measured"
            ),
            WatchDemoHealthSample(
                id = "00000000-0000-0000-0000-000000000002",
                metric = "heartRate",
                value = 72.0,
                unit = "beatsPerMinute",
                startTimeMilliseconds = 1_728_000_300_000,
                quality = "measured"
            ),
            WatchDemoHealthSample(
                id = "00000000-0000-0000-0000-000000000003",
                metric = "activeCalories",
                value = 184.0,
                unit = "kilocalories",
                startTimeMilliseconds = 1_728_000_600_000,
                quality = "estimated"
            ),
            WatchDemoHealthSample(
                id = "00000000-0000-0000-0000-000000000004",
                metric = "distance",
                value = 2_760.0,
                unit = "meters",
                startTimeMilliseconds = 1_728_000_900_000,
                quality = "measured"
            )
        )
    }
}

internal data class WatchDemoHealthSyncBatch(
    val protocolVersion: Int,
    val requestId: String,
    val sequence: Long,
    val nextCursor: Long,
    val samples: List<WatchDemoHealthSample>
)

internal data class WatchDemoHealthSample(
    val id: String,
    val metric: String,
    val value: Double,
    val unit: String,
    val startTimeMilliseconds: Long,
    val quality: String
)
