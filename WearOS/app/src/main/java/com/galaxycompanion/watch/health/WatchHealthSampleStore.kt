package com.galaxycompanion.watch.health

import android.content.Context
import android.os.SystemClock
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.IntervalDataPoint
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/**
 * Small, app-private queue of genuine Health Services readings. It is durable
 * across process death, bounded, and deliberately has no BLE access. The BLE
 * server obtains an immutable, cursor-bounded JSON batch from this repository;
 * it never receives a mutable Preferences editor or Health Services callback.
 */
class WatchHealthSampleStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE
    )

    /**
     * Persists one Health Services callback as one durable transaction.
     *
     * Passive Monitoring commonly batches several values together. Writing
     * every point independently used to repeatedly decode and re-encode the
     * entire private cache, which is wasteful on a small Watch battery.
     */
    fun appendPassiveData(dataPoints: DataPointContainer) {
        val bootInstant = bootInstant()
        val incoming = buildList {
            dataPoints.getData(DataType.HEART_RATE_BPM).forEach { point ->
                add(
                StoredWatchHealthSample(
                    id = UUID.randomUUID().toString(),
                    metric = "heartRate",
                    value = point.value,
                    unit = "beatsPerMinute",
                    startTimeMillis = point.getTimeInstant(bootInstant).toEpochMilli(),
                    endTimeMillis = null,
                    aggregation = AGGREGATION_INSTANTANEOUS
                )
                )
            }
            dataPoints.getData(DataType.STEPS_DAILY).forEach { point ->
                add(intervalSample(
                    "steps", point.value.toDouble(), "count", point, bootInstant,
                    AGGREGATION_DAILY_CUMULATIVE
                ))
            }
            dataPoints.getData(DataType.CALORIES_DAILY).forEach { point ->
            // Health Services daily calories include BMR. Preserve that fact
            // locally instead of relabeling the value as active calories.
                add(intervalSample(
                    "totalCalories", point.value, "kilocalories", point, bootInstant,
                    AGGREGATION_DAILY_CUMULATIVE
                ))
            }
            dataPoints.getData(DataType.DISTANCE_DAILY).forEach { point ->
                add(intervalSample(
                    "distance", point.value, "meters", point, bootInstant,
                    AGGREGATION_DAILY_CUMULATIVE
                ))
            }
            dataPoints.getData(DataType.FLOORS_DAILY).forEach { point ->
                add(intervalSample(
                    "floors", point.value, "count", point, bootInstant,
                    AGGREGATION_DAILY_CUMULATIVE
                ))
            }
            // Keep deltas distinct from the preceding daily snapshots. They
            // retain real time boundaries for local sleep analysis.
            dataPoints.getData(DataType.STEPS).forEach { point ->
                add(intervalSample(
                    "steps", point.value.toDouble(), "count", point, bootInstant,
                    AGGREGATION_INTERVAL
                ))
            }
            dataPoints.getData(DataType.DISTANCE).forEach { point ->
                add(intervalSample(
                    "distance", point.value, "meters", point, bootInstant,
                    AGGREGATION_INTERVAL
                ))
            }
            dataPoints.getData(DataType.FLOORS).forEach { point ->
                add(intervalSample(
                    "floors", point.value, "count", point, bootInstant,
                    AGGREGATION_INTERVAL
                ))
            }
        }
        appendAll(incoming)
    }

    fun summary(): WatchHealthStorageSummary = synchronized(LOCK) {
        val samples = load()
        WatchHealthStorageSummary(samples.size, samples.lastOrNull()?.summary)
    }

    /**
     * Returns the next bounded, immutable wire batch without acknowledging or
     * deleting Watch data. The iPhone owns its cursor after durable local
     * persistence, so a disconnected notification can safely be requested
     * again with the same `afterCursor`.
     */
    fun nextBatch(
        requestID: String,
        afterCursor: Long,
        maximumSampleCount: Int
    ): WatchHealthSyncBatch = synchronized(LOCK) {
        require(afterCursor >= 0L)
        require(maximumSampleCount in 1..MAXIMUM_SYNC_SAMPLE_COUNT)
        UUID.fromString(requestID)

        val samples = load().sortedBy(StoredWatchHealthSample::cursor)
        // Older private stores have no eviction watermark because they
        // predate physical health sync. Do not try to infer one from the
        // current rows: a normal aggregate correction creates the same shape
        // as an eviction. This version starts tracking only real future
        // capacity evictions; there is no pre-existing iPhone cursor to
        // reconcile from the earlier local-only implementation.
        val evictedThroughCursor = preferences
            .getLong(EVICTED_THROUGH_CURSOR_KEY, 0L)
            .coerceAtLeast(0L)
        if (WatchHealthRetentionWindow.requiresRecovery(afterCursor, evictedThroughCursor)) {
            return remoteFailureBatch(
                requestID = requestID,
                afterCursor = afterCursor,
                minimumRecoverableCursor = evictedThroughCursor,
                sequence = nextBatchSequence(samples)
            )
        }
        val selected = samples
            .asSequence()
            .filter { it.cursor > afterCursor }
            .take(maximumSampleCount)
            .toList()
        val nextCursor = selected.lastOrNull()?.cursor ?: afterCursor
        val sequence = nextBatchSequence(samples)
        WatchHealthSyncBatch(
            sequence = sequence,
            sampleCount = selected.size,
            isRemoteFailure = false,
            payload = JSONObject()
                .put("protocolVersion", PROTOCOL_VERSION)
                .put("requestID", requestID)
                .put("sequence", sequence)
                .put("nextCursor", nextCursor)
                .put("samples", JSONArray().apply {
                    selected.forEach { sample -> put(sample.toWireJson()) }
                })
                .toString()
                .encodeToByteArray()
        )
    }

    /**
     * Sends a value-level recovery signal instead of silently moving a stale
     * phone cursor over samples that fell out of the bounded Watch cache.
     * The GATT layer fragments and notifies this payload like a normal batch;
     * no local-health record is deleted or acknowledged here.
     */
    private fun remoteFailureBatch(
        requestID: String,
        afterCursor: Long,
        minimumRecoverableCursor: Long,
        sequence: Long
    ): WatchHealthSyncBatch = WatchHealthSyncBatch(
        sequence = sequence,
        sampleCount = 0,
        isRemoteFailure = true,
        payload = JSONObject()
            .put("protocolVersion", PROTOCOL_VERSION)
            .put("requestID", requestID)
            .put("sequence", sequence)
            .put("nextCursor", afterCursor)
            .put("samples", JSONArray())
            .put(
                "failure",
                JSONObject()
                    .put("code", "retentionGap")
                    // The v1 field name is retained for wire compatibility.
                    // Its value is the minimum safe `afterCursor`, not an
                    // inferred cursor of the first row currently in storage.
                    .put("earliestAvailableCursor", minimumRecoverableCursor)
            )
            .toString()
            .encodeToByteArray()
    )

    fun setPassiveCaptureEnabled(enabled: Boolean) = synchronized(LOCK) {
        check(preferences.edit().putBoolean(PASSIVE_CAPTURE_ENABLED_KEY, enabled).commit()) {
            "Unable to persist passive collection state"
        }
    }

    fun isPassiveCaptureEnabled(): Boolean = synchronized(LOCK) {
        preferences.getBoolean(PASSIVE_CAPTURE_ENABLED_KEY, false)
    }

    fun recordPermissionLoss() = synchronized(LOCK) {
        check(
            preferences.edit()
                .putBoolean(PERMISSION_LOST_KEY, true)
                .putBoolean(PASSIVE_CAPTURE_ENABLED_KEY, false)
                .commit()
        ) { "Unable to persist permission-loss state" }
    }

    fun consumePermissionLoss(): Boolean = synchronized(LOCK) {
        if (!preferences.getBoolean(PERMISSION_LOST_KEY, false)) {
            false
        } else {
            check(preferences.edit().remove(PERMISSION_LOST_KEY).commit()) {
                "Unable to clear permission-loss state"
            }
            true
        }
    }

    private fun intervalSample(
        metric: String,
        value: Double,
        unit: String,
        point: IntervalDataPoint<*>,
        bootInstant: Instant,
        aggregation: String
    ): StoredWatchHealthSample = StoredWatchHealthSample(
        id = UUID.randomUUID().toString(),
        metric = metric,
        value = value,
        unit = unit,
        startTimeMillis = point.getStartInstant(bootInstant).toEpochMilli(),
        endTimeMillis = point.getEndInstant(bootInstant).toEpochMilli(),
        aggregation = aggregation
    )

    private fun appendAll(incoming: List<StoredWatchHealthSample>) {
        if (incoming.isEmpty()) return
        synchronized(LOCK) {
            val samples = load().toMutableList()
            var nextCursor = maxOf(
                samples.maxOfOrNull(StoredWatchHealthSample::cursor) ?: 0L,
                preferences.getLong(NEXT_SAMPLE_CURSOR_KEY, 0L)
            )
            var changed = false
            incoming.forEach { sample ->
                val matchingIndex = samples.indexOfFirst { it.hasSameIntervalAs(sample) }
                if (matchingIndex >= 0) {
                    val existing = samples[matchingIndex]
                    if (existing.sameMeasurementAs(sample)) return@forEach
                    nextCursor = nextCursor.incrementCursor()
                    // A revised interval gets a later cursor but retains its
                    // stable id so iPhone can replace its local copy.
                    samples[matchingIndex] = sample.copy(id = existing.id, cursor = nextCursor)
                } else {
                    nextCursor = nextCursor.incrementCursor()
                    samples += sample.copy(cursor = nextCursor)
                }
                changed = true
            }
            if (!changed) return@synchronized

            val existingEvictionWatermark = preferences
                .getLong(EVICTED_THROUGH_CURSOR_KEY, 0L)
                .coerceAtLeast(0L)
            val retention = WatchHealthRetentionWindow.retain(
                samples = samples,
                maximumRetainedSamples = MAX_RETAINED_SAMPLES,
                previousEvictedThroughCursor = existingEvictionWatermark
            )
            // commit() is intentional for a callback-delivered health record:
            // the OS may unbind the passive service immediately afterwards.
            // All values for this callback are committed together.
            check(
                preferences.edit()
                    .putString(SAMPLES_KEY, encode(retention.retained))
                    .putLong(EVICTED_THROUGH_CURSOR_KEY, retention.evictedThroughCursor)
                    .putLong(NEXT_SAMPLE_CURSOR_KEY, nextCursor)
                    .commit()
            ) { "Unable to persist Health Services sample batch" }
        }
    }

    private fun load(): List<StoredWatchHealthSample> {
        return try {
            val array = JSONArray(preferences.getString(SAMPLES_KEY, "[]") ?: "[]")
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    val metric = item.getString("metric")
                    add(
                        StoredWatchHealthSample(
                            id = item.getString("id"),
                            metric = metric,
                            value = item.getDouble("value"),
                            unit = item.getString("unit"),
                            startTimeMillis = item.getLong("startTimeMillis"),
                            endTimeMillis = if (item.isNull("endTimeMillis")) null else item.getLong("endTimeMillis"),
                            // Original local-only releases stored daily totals
                            // for steps, distance and calories. Migrate those
                            // rows as such rather than fabricating intervals.
                            aggregation = item.optString(
                                "aggregation",
                                legacyAggregationFor(metric)
                            ),
                            // v1 records did not carry a sync cursor. Their
                            // JSON order is the previous durable insertion
                            // order, so it is the only safe migration order.
                            cursor = item.optLong("cursor", index + 1L).coerceAtLeast(1L)
                        )
                    )
                }
            }
        } catch (error: Exception) {
            throw IllegalStateException("Health Services sample storage is unreadable", error)
        }
    }

    private fun encode(samples: List<StoredWatchHealthSample>): String = JSONArray().apply {
        samples.forEach { sample ->
            put(
                JSONObject()
                    .put("id", sample.id)
                    .put("metric", sample.metric)
                    .put("value", sample.value)
                    .put("unit", sample.unit)
                    .put("startTimeMillis", sample.startTimeMillis)
                    .put("endTimeMillis", sample.endTimeMillis)
                    .put("aggregation", sample.aggregation)
                    .put("cursor", sample.cursor)
            )
        }
    }.toString()

    private fun nextBatchSequence(samples: List<StoredWatchHealthSample>): Long {
        val baseline = maxOf(
            preferences.getLong(NEXT_BATCH_SEQUENCE_KEY, 0L),
            samples.maxOfOrNull(StoredWatchHealthSample::cursor) ?: 0L
        )
        val next = baseline + 1L
        check(next > 0L) { "Health sync sequence overflow" }
        check(preferences.edit().putLong(NEXT_BATCH_SEQUENCE_KEY, next).commit()) {
            "Unable to persist Health sync sequence"
        }
        return next
    }

    private fun bootInstant(): Instant = Instant.ofEpochMilli(
        System.currentTimeMillis() - SystemClock.elapsedRealtime()
    )

    private companion object {
        const val PREFERENCES_NAME = "galaxy_companion_real_health"
        const val SAMPLES_KEY = "version_1_samples"
        const val PERMISSION_LOST_KEY = "permission_lost"
        const val PASSIVE_CAPTURE_ENABLED_KEY = "passive_capture_enabled"
        const val NEXT_SAMPLE_CURSOR_KEY = "next_sample_cursor"
        const val NEXT_BATCH_SEQUENCE_KEY = "next_batch_sequence"
        // This watermark changes only when the capacity policy really drops
        // records. It intentionally does not track gaps caused by a revised
        // daily aggregate retaining its stable UUID with a newer cursor.
        const val EVICTED_THROUGH_CURSOR_KEY = "evicted_through_cursor"
        const val MAX_RETAINED_SAMPLES = 2_000
        const val MAXIMUM_SYNC_SAMPLE_COUNT = 20
        const val PROTOCOL_VERSION = 1
        const val AGGREGATION_INSTANTANEOUS = "instantaneous"
        const val AGGREGATION_INTERVAL = "interval"
        const val AGGREGATION_DAILY_CUMULATIVE = "dailyCumulative"
        val LOCK = Any()

        fun legacyAggregationFor(metric: String): String = when (metric) {
            "steps", "distance", "totalCalories" -> AGGREGATION_DAILY_CUMULATIVE
            else -> AGGREGATION_INSTANTANEOUS
        }
    }
}

data class StoredWatchHealthSample(
    val id: String,
    val metric: String,
    val value: Double,
    val unit: String,
    val startTimeMillis: Long,
    val endTimeMillis: Long?,
    val aggregation: String = "instantaneous",
    val cursor: Long = 0L
) {
    val summary: String
        get() = "$metric: $value $unit"

    fun sameMeasurementAs(other: StoredWatchHealthSample): Boolean =
        metric == other.metric &&
            value == other.value &&
            unit == other.unit &&
            startTimeMillis == other.startTimeMillis &&
            endTimeMillis == other.endTimeMillis &&
            aggregation == other.aggregation

    fun hasSameIntervalAs(other: StoredWatchHealthSample): Boolean =
        metric == other.metric &&
            startTimeMillis == other.startTimeMillis &&
            endTimeMillis == other.endTimeMillis &&
            aggregation == other.aggregation

    fun toWireJson(): JSONObject {
        val metricForProtocol = protocolMetric()
        val unitForProtocol = when (unit) {
            "beatsPerMinute", "count", "meters", "kilocalories" -> unit
            else -> throw IllegalStateException("Unsupported stored health unit: $unit")
        }
        val aggregationForProtocol = when (aggregation) {
            "instantaneous", "interval", "dailyCumulative" -> aggregation
            else -> throw IllegalStateException("Unsupported health aggregation: $aggregation")
        }
        return JSONObject()
            .put("id", id)
            .put("metric", metricForProtocol)
            .put("value", value)
            .put("unit", unitForProtocol)
            .put("startTime", startTimeMillis)
            .put("endTime", endTimeMillis)
            .put("source", "wearHealthServices")
            .put("quality", "measured")
            .put("revision", cursor)
            .put("aggregation", aggregationForProtocol)
    }

    internal fun protocolMetric(): String = when (metric) {
        "heartRate", "steps", "distance", "totalCalories", "floors" -> metric
        else -> throw IllegalStateException("Unsupported stored health metric: $metric")
    }
}

private fun Long.incrementCursor(): Long {
    check(this < Long.MAX_VALUE) { "Health sample cursor overflow" }
    return this + 1L
}

data class WatchHealthStorageSummary(
    val sampleCount: Int,
    val latestSample: String?
)

data class WatchHealthSyncBatch(
    val sequence: Long,
    val sampleCount: Int,
    val isRemoteFailure: Boolean,
    val payload: ByteArray
)
