package com.galaxycompanion.watch.health

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.health.services.client.HealthServices
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.PassiveListenerConfig
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

data class WatchHealthCaptureSnapshot(
    val status: String,
    val storedSampleCount: Int?,
    val latestSample: String?
)

/**
 * Registers only user-authorized passive Health Services recording.
 *
 * This controller deliberately does not use MeasureClient or show a live
 * heart-rate stream. Health Services batches background samples into the
 * Watch-private store; a person chooses when to pull that cache from iPhone.
 */
class WatchHealthCaptureController(
    context: Context,
    private val capabilities: () -> WatchHealthCapabilitySnapshot,
    private val onSnapshotChanged: (WatchHealthCaptureSnapshot) -> Unit
) {
    private val applicationContext = context.applicationContext
    private val healthServices = HealthServices.getClient(applicationContext)
    private val sampleStore = WatchHealthSampleStore(applicationContext)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var status = "尚未请求本地健康采集权限"

    @Volatile
    private var passiveCaptureEnabled = false
    @Volatile
    private var passiveCaptureUnknown = false
    @Volatile
    private var closed = false

    fun requiredPermissions(): List<String> {
        val available = capabilities().metricNames
        return buildList {
            if (available.any { it in DAILY_METRICS }) add(Manifest.permission.ACTIVITY_RECOGNITION)
            if ("heartRate" in available) add(heartRatePermission())
        }
    }

    /** Starts the one-time-approved local recording registration. */
    fun startAfterPermissionRequest() {
        if (closed) return
        executor.execute {
            if (closed) return@execute
            if (passiveCaptureUnknown) {
                status = "本地健康记录状态未知；请先暂停记录，再重新开启。"
                publish()
                return@execute
            }
            val currentCapabilities = capabilities()
            val canReadActivity = hasPermission(Manifest.permission.ACTIVITY_RECOGNITION)
            val canReadHeartRate = hasPermission(heartRatePermission())
            val requestedPassive = buildSet {
                if (canReadHeartRate && currentCapabilities.supportsPassiveHeartRate) {
                    add(DataType.HEART_RATE_BPM)
                }
                if (canReadActivity && currentCapabilities.supportsPassiveDailySteps) {
                    add(DataType.STEPS_DAILY)
                }
                if (canReadActivity && currentCapabilities.supportsPassiveDailyCalories) {
                    add(DataType.CALORIES_DAILY)
                }
                if (canReadActivity && currentCapabilities.supportsPassiveDailyDistance) {
                    add(DataType.DISTANCE_DAILY)
                }
                // These deltas retain their actual interval boundaries. They
                // are never relabelled as daily totals, and are the only
                // activity values used by the iPhone's local sleep analysis.
                if (canReadActivity && currentCapabilities.supportsPassiveGranularSteps) {
                    add(DataType.STEPS)
                }
                if (canReadActivity && currentCapabilities.supportsPassiveGranularDistance) {
                    add(DataType.DISTANCE)
                }
            }
            val messages = mutableListOf<String>()

            if (requestedPassive.isNotEmpty()) {
                try {
                    val config = PassiveListenerConfig.builder().setDataTypes(requestedPassive).build()
                    healthServices.passiveMonitoringClient
                        .setPassiveListenerServiceAsync(GalaxyPassiveHealthService::class.java, config)
                        .get()
                    sampleStore.setPassiveCaptureEnabled(true)
                    passiveCaptureEnabled = true
                    passiveCaptureUnknown = false
                    if (
                        currentCapabilities.supportsPassiveDailySteps ||
                        currentCapabilities.supportsPassiveDailyCalories ||
                        currentCapabilities.supportsPassiveDailyDistance
                    ) {
                        messages += "基础日累计指标"
                    }
                    if (currentCapabilities.supportsPassiveHeartRate) {
                        messages += "后台心率记录"
                    }
                    if (
                        currentCapabilities.supportsPassiveGranularSteps ||
                        currentCapabilities.supportsPassiveGranularDistance
                    ) {
                        messages += "活动增量记录"
                    }
                } catch (_: Exception) {
                    val listenerCleared = runCatching {
                        healthServices.passiveMonitoringClient.clearPassiveListenerServiceAsync().get()
                    }.isSuccess
                    passiveCaptureEnabled = false
                    passiveCaptureUnknown = !listenerCleared
                    if (listenerCleared) {
                        runCatching { sampleStore.setPassiveCaptureEnabled(false) }
                    }
                    messages += if (listenerCleared) "被动健康采集失败" else "被动监听状态未知"
                }
            }

            status = when {
                messages.isEmpty() -> "未获必要权限或此设备不支持基础 Health Services 指标。"
                else -> "已开启 Watch 本地健康记录：${messages.joinToString("、")}。不显示实时数据；在 iPhone 手动同步时回传。"
            }
            publish()
        }
    }

    fun stopPassiveCapture() {
        executor.execute {
            val listenerCleared = try {
                healthServices.passiveMonitoringClient.clearPassiveListenerServiceAsync().get()
                true
            } catch (_: Exception) {
                false
            }
            if (!listenerCleared) {
                passiveCaptureUnknown = true
                status = "未能确认已暂停本地健康记录；监听可能仍在运行，请重试。"
                publish()
                return@execute
            }

            passiveCaptureEnabled = false
            passiveCaptureUnknown = false
            try {
                sampleStore.setPassiveCaptureEnabled(false)
                status = "Watch 本地健康记录已暂停；iPhone 不会再收到新的本机记录。"
            } catch (error: Exception) {
                status = "已暂停本地健康记录，但无法保存状态：${error.localizedMessage ?: error.javaClass.simpleName}"
            }
            publish()
        }
    }

    fun refreshSummary() {
        try {
            if (sampleStore.consumePermissionLoss()) {
                passiveCaptureEnabled = false
                passiveCaptureUnknown = false
                sampleStore.setPassiveCaptureEnabled(false)
                status = "Health Services 已撤销被动采集权限；请重新授权。"
            } else if (sampleStore.isPassiveCaptureEnabled()) {
                // Health Services owns this registration independently from
                // the activity lifecycle. Do not require the person to
                // re-enable it merely because the Watch UI restarted.
                passiveCaptureEnabled = true
                passiveCaptureUnknown = false
                status = "Watch 本地健康记录已开启；Health Services 会按系统节奏分批保存，等待 iPhone 手动同步。"
            }
        } catch (error: Exception) {
            status = "本地健康存储不可用：${error.localizedMessage ?: error.javaClass.simpleName}"
        }
        publish()
    }

    fun close() {
        if (closed) return
        closed = true
        executor.shutdown()
    }

    private fun publish() {
        try {
            val storage = sampleStore.summary()
            val passiveSuffix = when {
                passiveCaptureEnabled -> " 后台本地记录已开启。"
                passiveCaptureUnknown -> " 本地记录状态未知，可点暂停确认。"
                else -> ""
            }
            onSnapshotChanged(
                WatchHealthCaptureSnapshot(
                    status + passiveSuffix,
                    storage.sampleCount,
                    storage.latestSample
                )
            )
        } catch (error: Exception) {
            onSnapshotChanged(
                WatchHealthCaptureSnapshot(
                    "本地健康存储不可用：${error.localizedMessage ?: error.javaClass.simpleName}",
                    null,
                    null
                )
            )
        }
    }

    private fun hasPermission(permission: String): Boolean =
        applicationContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun heartRatePermission(): String = if (Build.VERSION.SDK_INT >= 36) {
        // API 36 Health Services migration: android.permission.health.READ_HEART_RATE.
        "android.permission.health.READ_HEART_RATE"
    } else {
        Manifest.permission.BODY_SENSORS
    }

    private companion object {
        val DAILY_METRICS = setOf("steps", "calories", "distance")
    }
}
