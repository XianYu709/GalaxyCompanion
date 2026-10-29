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

    fun appendHeartRate(dataPoints: DataPointContainer) {
        val bootInstant = bootInstant()
        dataPoints.getData(DataType.HEART_RATE_BPM).forEach { point ->
            append(
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
    }

    fun appendPassiveDailyMetrics(dataPoints: DataPointContainer) {
        val bootInstant = bootInstant()
        dataPoints.getData(DataType.STEPS_DAILY).forEach { point ->
            appendInterval(
                "steps",
                point.value.toDouble(),
                "count",
                point,
                bootInstant,
                AGGREGATION_DAILY_CUMULATIVE
            )
        }
        dataPoints.getData(DataType.CALORIES_DAILY).forEach { point ->
            // Health Services daily calories include BMR. Preserve that fact
            // locally instead of relabeling the value as active calories.
            appendInterval(
                "totalCalories",
                point.value,
                "kilocalories",
                point,
                bootInstant,
                AGGREGATION_DAILY_CUMULATIVE
            )
        }
        dataPoints.getData(DataType.DISTANCE_DAILY).forEach { point ->
            appendInterval(
                "distance",
                point.value,
                "meters",
                point,
                bootInstant,
                AGGREGATION_DAILY_CUMULATIVE
            )
        }
    }

    /**
     * Persists genuine Health Services deltas without collapsing them into a
     * day total. Their interval boundaries are used on iPhone for both safe
     * HealthKit export and conservative local sleep analysis.
     */
    fun appendPassiveGranularActivity(dataPoints: DataPointContainer) {
        val bootInstant = bootInstant()
        dataPoints.getData(DataType.STEPS).forEach { point ->
            appendInterval(
                "steps",
                point.value.toDouble(),
                "count",
                point,
                bootInstant,
                AGGREGATION_INTERVAL
            )
        }
        dataPoints.getData(DataType.DISTANCE).forEach { point ->
            appendInterval(
                "distance",
                point.value,
                "meters",
                point,
                bootInstant,
                AGGREGATION_INTERVAL
            )
        }
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

    private fun appendInterval(
        metric: String,
        value: Double,
        unit: String,
        point: IntervalDataPoint<*>,
        bootInstant: Instant,
        aggregation: String
    ) {
        append(
            StoredWatchHealthSample(
                id = UUID.randomUUID().toString(),
                metric = metric,
                value = value,
                unit = unit,
                startTimeMillis = point.getStartInstant(bootInstant).toEpochMilli(),
                endTimeMillis = point.getEndInstant(bootInstant).toEpochMilli(),
                aggregation = aggregation
            )
        )
    }

    private fun append(sample: StoredWatchHealthSample) {
        synchronized(LOCK) {
            val samples = load().toMutableList()
            val matchingIndex = samples.indexOfFirst { it.hasSameIntervalAs(sample) }
            if (matchingIndex >= 0) {
                val existing = samples[matchingIndex]
                if (existing.sameMeasurementAs(sample)) return@synchronized
                // A revised interval must get a later cursor. The original
                // sample ID is kept so phone-side storage can treat this as a
                // correction rather than a second measurement.
                samples[matchingIndex] = sample.copy(
                    id = existing.id,
                    cursor = nextSampleCursor(samples)
                )
            } else {
                samples += sample.copy(cursor = nextSampleCursor(samples))
            }
            val existingEvictionWatermark = preferences
                .getLong(EVICTED_THROUGH_CURSOR_KEY, 0L)
                .coerceAtLeast(0L)
            val retention = WatchHealthRetentionWindow.retain(
                samples = samples,
                maximumRetainedSamples = MAX_RETAINED_SAMPLES,
                previousEvictedThroughCursor = existingEvictionWatermark
            )
            // commit() is intentional for a callback-delivered health record: the
            // operating system may unbind the passive service after this method.
            check(
                preferences.edit()
                    .putString(
                        SAMPLES_KEY,
                        encode(retention.retained)
                    )
                    .putLong(EVICTED_THROUGH_CURSOR_KEY, retention.evictedThroughCursor)
                    .commit()
            ) { "Unable to persist Health Services sample" }
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

    private fun nextSampleCursor(samples: List<StoredWatchHealthSample>): Long {
        val highestStored = samples.maxOfOrNull(StoredWatchHealthSample::cursor) ?: 0L
        val highestPersisted = preferences.getLong(NEXT_SAMPLE_CURSOR_KEY, 0L)
        val next = maxOf(highestStored, highestPersisted) + 1L
        check(next > 0L) { "Health sample cursor overflow" }
        check(preferences.edit().putLong(NEXT_SAMPLE_CURSOR_KEY, next).commit()) {
            "Unable to persist Health Services sample cursor"
        }
        return next
    }

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
        val metricForProtocol = when (metric) {
            "heartRate", "steps", "distance", "totalCalories" -> metric
            else -> throw IllegalStateException("Unsupported stored health metric: $metric")
        }
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
