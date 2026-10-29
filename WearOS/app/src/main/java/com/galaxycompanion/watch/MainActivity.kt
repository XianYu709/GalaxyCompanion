package com.galaxycompanion.watch

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.Card
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.Text
import com.galaxycompanion.watch.ble.BleFoundationResult
import com.galaxycompanion.watch.ble.WatchBleController
import com.galaxycompanion.watch.health.WatchHealthCapabilityProbe
import com.galaxycompanion.watch.health.WatchHealthCapabilitySnapshot
import com.galaxycompanion.watch.health.WatchHealthCaptureController
import com.galaxycompanion.watch.health.WatchHealthCaptureSnapshot

class MainActivity : ComponentActivity() {
    private var status by mutableStateOf("等待启动 GalaxyCompanion BLE 服务")
    private var manualSyncStatus by mutableStateOf("尚未收到 iPhone 的手动同步请求")
    private var healthCapabilities by mutableStateOf(WatchHealthCapabilitySnapshot.checking())
    private var healthCapture by mutableStateOf(
        WatchHealthCaptureSnapshot("尚未请求本地健康采集权限", 0, null)
    )
    private val healthProbe by lazy {
        WatchHealthCapabilityProbe(applicationContext) { snapshot ->
            runOnUiThread { healthCapabilities = snapshot }
        }
    }
    private val bleController by lazy {
        WatchBleController(
            context = applicationContext,
            healthCapabilities = healthProbe::snapshot,
            onAdvertisementResult = { result ->
                runOnUiThread { updateStatus(result) }
            },
            onManualSyncStatus = { syncStatus ->
                runOnUiThread { manualSyncStatus = syncStatus }
            }
        )
    }
    private val healthCaptureController by lazy {
        WatchHealthCaptureController(applicationContext, healthProbe::snapshot) { snapshot ->
            runOnUiThread { healthCapture = snapshot }
        }
    }

    private val bluetoothPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        val granted = grants.values.all { it }
        if (granted) {
            updateStatus(bleController.start())
        } else {
            status = "需要蓝牙权限才能让 iPhone 发现手表服务。"
        }
    }
    private val healthPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        healthCaptureController.startAfterPermissionRequest()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        healthProbe.refresh()
        healthCaptureController.refreshSummary()
        setContent {
            GalaxyCompanionWatchApp(
                status = status,
                manualSyncStatus = manualSyncStatus,
                healthCapabilities = healthCapabilities,
                healthCapture = healthCapture,
                onStart = ::requestBluetoothAndStart,
                onRefreshHealthCapabilities = healthProbe::refresh,
                onStartLocalHealthCapture = ::requestHealthAndStartCapture,
                onStopPassiveCapture = healthCaptureController::stopPassiveCapture,
                onStop = {
                    bleController.stop()
                    status = "BLE 服务已停止"
                }
            )
        }
    }

    override fun onDestroy() {
        bleController.stop()
        healthCaptureController.close()
        healthProbe.close()
        super.onDestroy()
    }

    private fun requestBluetoothAndStart() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            updateStatus(bleController.start())
            return
        }

        val permissions = arrayOf(
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_SCAN
        )
        val missingPermissions = permissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }

        if (missingPermissions.isEmpty()) {
            updateStatus(bleController.start())
        } else {
            bluetoothPermissions.launch(missingPermissions.toTypedArray())
        }
    }

    private fun requestHealthAndStartCapture() {
        val missingPermissions = healthCaptureController.requiredPermissions().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isEmpty()) {
            healthCaptureController.startAfterPermissionRequest()
        } else {
            healthPermissions.launch(missingPermissions.toTypedArray())
        }
    }

    private fun updateStatus(result: BleFoundationResult) {
        status = when (result) {
            BleFoundationResult.Starting -> "正在启动可连接的 BLE 广播…"
            BleFoundationResult.Started -> "BLE 服务正在广播；现在可在 iPhone 上搜索手表。"
            is BleFoundationResult.Unavailable -> result.reason
        }
    }
}

@Composable
private fun GalaxyCompanionWatchApp(
    status: String,
    manualSyncStatus: String,
    healthCapabilities: WatchHealthCapabilitySnapshot,
    healthCapture: WatchHealthCaptureSnapshot,
    onStart: () -> Unit,
    onRefreshHealthCapabilities: () -> Unit,
    onStartLocalHealthCapture: () -> Unit,
    onStopPassiveCapture: () -> Unit,
    onStop: () -> Unit
) {
    MaterialTheme {
        val scrollState = rememberScalingLazyListState()
        ScalingLazyColumn(
            modifier = Modifier
                .fillMaxSize(),
            state = scrollState,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            item {
                Column(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text("GalaxyCompanion")
                    Text("连接与健康")
                }
            }
            item {
                WatchInfoCard(title = "BLE 连接", detail = status)
            }
            item {
                Button(onClick = onStart) { Text("启动 BLE") }
            }
            item {
                Button(onClick = onStop) { Text("停止连接") }
            }
            item {
                WatchInfoCard(
                    title = "安全配对",
                    detail = "在 iPhone 请求验证后，按双方系统提示完成蓝牙配对。健康数据只会在当前受保护连接中同步。"
                )
            }
            item {
                WatchInfoCard(title = "手动同步状态", detail = manualSyncStatus)
            }
            item {
                WatchInfoCard(
                    title = "Health Services",
                    detail = healthCapabilities.status
                )
            }
            item {
                WatchInfoCard(
                    title = "可用指标",
                    detail = if (healthCapabilities.metricNames.isEmpty()) {
                        "等待检查或此手表未报告基础指标"
                    } else {
                        healthCapabilities.displayMetrics
                    }
                )
            }
            item {
                WatchInfoCard(
                    title = "睡眠输入",
                    detail = if (healthCapabilities.supportsSleepInputs) {
                        "真机支持后台心率和活动增量。本机只做留存；iPhone 手动同步后再本地估算睡眠。"
                    } else {
                        "后台心率或活动增量尚未由 Health Services 支持；不会生成睡眠估算。"
                    }
                )
            }
            item {
                Button(onClick = onRefreshHealthCapabilities) { Text("刷新健康能力") }
            }
            item {
                WatchInfoCard(title = "本地健康记录", detail = healthCapture.status)
            }
            item {
                WatchInfoCard(
                    title = "本地真实样本",
                    detail = buildString {
                        append(healthCapture.storedSampleCount?.toString() ?: "无法读取")
                        healthCapture.latestSample?.let { append(" · $it") }
                    }
                )
            }
            item {
                Button(onClick = onStartLocalHealthCapture) { Text("开启本地健康记录") }
            }
            item {
                Button(onClick = onStopPassiveCapture) { Text("暂停本地健康记录") }
            }
        }
    }
}

@Composable
private fun WatchInfoCard(title: String, detail: String) {
    Card(
        onClick = {},
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(title)
            Text(detail)
        }
    }
}
