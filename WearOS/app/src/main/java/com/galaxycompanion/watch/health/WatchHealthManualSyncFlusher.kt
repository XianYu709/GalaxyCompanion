package com.galaxycompanion.watch.health

import android.content.Context
import androidx.health.services.client.HealthServices
import java.util.concurrent.TimeUnit

/**
 * Best-effort preparation for a user initiated iPhone pull.
 *
 * Health Services owns passive delivery cadence, so this is not a live data
 * stream and it never promises a new reading. It merely asks the platform to
 * flush the registered passive sources before the GATT server snapshots the
 * app-private cache. A throttled or failed flush intentionally falls back to
 * the durable cache rather than turning a safe manual sync into a failure.
 */
class WatchHealthManualSyncFlusher(context: Context) {
    private val applicationContext = context.applicationContext
    private val healthServices = HealthServices.getClient(applicationContext)
    private val sampleStore = WatchHealthSampleStore(applicationContext)

    fun flushBeforeManualPull(): ManualHealthFlushResult {
        val recordingEnabled = try {
            sampleStore.isPassiveCaptureEnabled()
        } catch (error: Exception) {
            return ManualHealthFlushResult.CacheStatusUnavailable(
                error.localizedMessage ?: error.javaClass.simpleName
            )
        }
        if (!recordingEnabled) return ManualHealthFlushResult.NotRecording

        return try {
            // Manual pulls are intentionally infrequent. Do not let a
            // platform-throttled flush consume the iPhone's GATT request
            // timeout; cached samples remain safe to return immediately.
            healthServices.passiveMonitoringClient.flushAsync().get(3, TimeUnit.SECONDS)
            ManualHealthFlushResult.Completed
        } catch (error: Exception) {
            ManualHealthFlushResult.Deferred(
                error.localizedMessage ?: error.javaClass.simpleName
            )
        }
    }
}

sealed interface ManualHealthFlushResult {
    data object Completed : ManualHealthFlushResult
    data object NotRecording : ManualHealthFlushResult
    data class CacheStatusUnavailable(val reason: String) : ManualHealthFlushResult
    data class Deferred(val reason: String) : ManualHealthFlushResult
}
