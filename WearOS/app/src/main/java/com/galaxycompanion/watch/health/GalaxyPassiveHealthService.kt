package com.galaxycompanion.watch.health

import android.util.Log
import androidx.health.services.client.PassiveListenerService
import androidx.health.services.client.data.DataPointContainer

/**
 * System-bound receiver for Health Services passive updates. The manifest
 * binding permission restricts this service to Health Services; values remain
 * in WatchHealthSampleStore until an authenticated iPhone connection requests
 * an incremental sync batch. Daily totals and granular activity deltas stay
 * semantically distinct so iPhone never mistakes one for the other.
 */
class GalaxyPassiveHealthService : PassiveListenerService() {
    override fun onNewDataPointsReceived(dataPoints: DataPointContainer) {
        try {
            WatchHealthSampleStore(applicationContext).apply {
                appendHeartRate(dataPoints)
                appendPassiveDailyMetrics(dataPoints)
                appendPassiveGranularActivity(dataPoints)
            }
        } catch (error: Exception) {
            Log.e(TAG, "Unable to persist Health Services data (${error.javaClass.simpleName})")
        }
    }

    override fun onPermissionLost() {
        runCatching {
            WatchHealthSampleStore(applicationContext).recordPermissionLoss()
        }.onFailure { error ->
            Log.e(TAG, "Unable to record permission loss (${error.javaClass.simpleName})")
        }
    }

    private companion object {
        const val TAG = "GalaxyHealthService"
    }
}
