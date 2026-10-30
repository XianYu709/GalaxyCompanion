package com.galaxycompanion.watch.health

import android.content.Context
import android.os.Build
import androidx.health.services.client.HealthServices
import androidx.health.services.client.data.DataType
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Snapshot returned by the watch's app-owned GATT capability characteristic.
 *
 * Values are derived from Health Services at runtime rather than from a Galaxy
 * Watch model allow-list. This avoids advertising a metric that the device or
 * installed Health Services provider has not made available to this app.
 *
 * API references:
 * - https://developer.android.com/reference/kotlin/androidx/health/services/client/PassiveMonitoringClient
 */
data class WatchHealthCapabilitySnapshot(
    val model: String,
    val wearOsVersion: String,
    val firmwareVersion: String,
    val metricNames: Set<String>,
    /**
     * The full passive Health Services inventory reported by this exact
     * Watch/runtime. These are diagnostic capability names only: collecting
     * a type still requires an explicit, semantically safe implementation.
     */
    val passiveDataTypeNames: Set<String>,
    /** Health Services reports these per-device at runtime; never assume them. */
    val supportsPassiveHeartRate: Boolean,
    val supportsPassiveDailySteps: Boolean,
    val supportsPassiveDailyCalories: Boolean,
    val supportsPassiveDailyDistance: Boolean,
    val supportsPassiveDailyFloors: Boolean,
    val supportsPassiveGranularSteps: Boolean,
    val supportsPassiveGranularDistance: Boolean,
    val supportsPassiveGranularFloors: Boolean,
    val status: String
) {
    val displayMetrics: String
        get() = metricNames.map(::displayName).sorted().joinToString(" · ")

    val supportsSleepInputs: Boolean
        get() = supportsPassiveHeartRate &&
            (supportsPassiveGranularSteps || supportsPassiveGranularDistance)

    companion object {
        fun checking() = WatchHealthCapabilitySnapshot(
            model = Build.MODEL ?: "未知 Wear OS 手表",
            wearOsVersion = "Wear OS ${Build.VERSION.RELEASE}",
            firmwareVersion = Build.DISPLAY ?: "未知",
            metricNames = emptySet(),
            passiveDataTypeNames = emptySet(),
            supportsPassiveHeartRate = false,
            supportsPassiveDailySteps = false,
            supportsPassiveDailyCalories = false,
            supportsPassiveDailyDistance = false,
            supportsPassiveDailyFloors = false,
            supportsPassiveGranularSteps = false,
            supportsPassiveGranularDistance = false,
            supportsPassiveGranularFloors = false,
            status = "正在检查 Health Services 支持情况…"
        )

        private fun displayName(metric: String): String = when (metric) {
            "heartRate" -> "心率"
            "steps" -> "步数"
            "calories" -> "卡路里"
            "distance" -> "距离"
            else -> metric
        }
    }
}

class WatchHealthCapabilityProbe(
    context: Context,
    private val onSnapshotChanged: (WatchHealthCapabilitySnapshot) -> Unit
) {
    private val applicationContext = context.applicationContext
    private val healthServices = HealthServices.getClient(applicationContext)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var current = WatchHealthCapabilitySnapshot.checking()

    fun snapshot(): WatchHealthCapabilitySnapshot = current

    fun refresh() {
        current = current.copy(status = "正在检查 Health Services 支持情况…")
        onSnapshotChanged(current)
        executor.execute {
            val next = try {
                val passiveCapabilities = healthServices.passiveMonitoringClient.getCapabilitiesAsync().get()
                val supportedPassive = passiveCapabilities.supportedDataTypesPassiveMonitoring
                val supportsPassiveHeartRate = DataType.HEART_RATE_BPM in supportedPassive
                val supportsPassiveDailySteps = DataType.STEPS_DAILY in supportedPassive
                val supportsPassiveDailyCalories = DataType.CALORIES_DAILY in supportedPassive
                val supportsPassiveDailyDistance = DataType.DISTANCE_DAILY in supportedPassive
                val supportsPassiveDailyFloors = DataType.FLOORS_DAILY in supportedPassive
                val supportsPassiveGranularSteps = DataType.STEPS in supportedPassive
                val supportsPassiveGranularDistance = DataType.DISTANCE in supportedPassive
                val supportsPassiveGranularFloors = DataType.FLOORS in supportedPassive
                val metrics = buildSet {
                    if (supportsPassiveHeartRate) {
                        add("heartRate")
                    }
                    if (supportsPassiveDailySteps || supportsPassiveGranularSteps) {
                        add("steps")
                    }
                    if (supportsPassiveDailyCalories) {
                        add("calories")
                    }
                    if (supportsPassiveDailyDistance || supportsPassiveGranularDistance) {
                        add("distance")
                    }
                    if (supportsPassiveDailyFloors || supportsPassiveGranularFloors) {
                        add("floors")
                    }
                }
                WatchHealthCapabilitySnapshot.checking().copy(
                    metricNames = metrics,
                    passiveDataTypeNames = supportedPassive.map { it.name }.toSet(),
                    supportsPassiveHeartRate = supportsPassiveHeartRate,
                    supportsPassiveDailySteps = supportsPassiveDailySteps,
                    supportsPassiveDailyCalories = supportsPassiveDailyCalories,
                    supportsPassiveDailyDistance = supportsPassiveDailyDistance,
                    supportsPassiveDailyFloors = supportsPassiveDailyFloors,
                    supportsPassiveGranularSteps = supportsPassiveGranularSteps,
                    supportsPassiveGranularDistance = supportsPassiveGranularDistance,
                    supportsPassiveGranularFloors = supportsPassiveGranularFloors,
                    status = if (metrics.isEmpty()) {
                        "Health Services 未报告可供本应用使用的基础指标"
                    } else {
                        if (supportsPassiveHeartRate &&
                            (supportsPassiveGranularSteps || supportsPassiveGranularDistance)
                        ) {
                            "已读取真实设备能力；可请求低频后台心率与活动增量，为本地睡眠分析提供输入。"
                        } else {
                            "已读取真实设备能力；睡眠分析所需的后台心率或活动增量仍需由真机确认。"
                        }
                    }
                )
            } catch (error: Exception) {
                WatchHealthCapabilitySnapshot.checking().copy(
                    status = "无法读取 Health Services 能力：${error.localizedMessage ?: error.javaClass.simpleName}"
                )
            }
            current = next
            onSnapshotChanged(next)
        }
    }

    fun close() {
        executor.shutdown()
    }
}
