package com.galaxycompanion.watch

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import com.galaxycompanion.watch.ble.BleFoundationResult
import com.galaxycompanion.watch.ble.WatchBleController
import com.galaxycompanion.watch.health.WatchHealthCapabilityProbe
import com.galaxycompanion.watch.health.WatchHealthCapabilitySnapshot
import com.galaxycompanion.watch.health.WatchHealthCaptureController
import com.galaxycompanion.watch.health.WatchHealthCaptureSnapshot

/**
 * The Watch is intentionally a low-interaction data source. Starting it asks
 * for only the necessary platform permissions, begins balanced BLE
 * advertising and persists Health Services' passive batches. Pairing,
 * manual pulls, Apple Health and diagnostics belong to the iPhone app.
 */
class MainActivity : ComponentActivity() {
    private var status by mutableStateOf("点按启动后，可由 iPhone 搜索此 Watch。")
    private var healthCapabilities by mutableStateOf(WatchHealthCapabilitySnapshot.checking())
    private var healthCapture by mutableStateOf(
        WatchHealthCaptureSnapshot("等待启动本地健康记录", 0, null)
    )
    private var startInProgress by mutableStateOf(false)
    private var startRequested = false
    private var healthStartDispatched = false
    private var healthPermissionRequestInFlight = false

    private val healthProbe by lazy {
        WatchHealthCapabilityProbe(applicationContext) { snapshot ->
            runOnUiThread {
                healthCapabilities = snapshot
                ensurePassiveHealthRecordingIfRequested()
            }
        }
    }
    private val bleController by lazy {
        WatchBleController(
            context = applicationContext,
            healthCapabilities = healthProbe::snapshot,
            onAdvertisementResult = { result -> runOnUiThread { updateStatus(result) } },
            // The iPhone displays per-pull transport diagnostics. The Watch
            // remains a simple, tappable source screen.
            onManualSyncStatus = {}
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
        if (grants.values.all { it }) {
            updateStatus(bleController.start())
        } else {
            startInProgress = false
            status = "需要蓝牙权限才能让 iPhone 发现手表服务。"
        }
        ensurePassiveHealthRecordingIfRequested()
    }

    private val healthPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        healthPermissionRequestInFlight = false
        // The controller checks the actual grants and reports an actionable
        // status when Health Services cannot start. No separate Watch switch
        // is needed after the one Start action.
        healthCaptureController.startAfterPermissionRequest()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        healthProbe.refresh()
        healthCaptureController.refreshSummary()
        setContent {
            GalaxyCompanionWatchApp(
                bleStatus = status,
                healthCapture = healthCapture,
                startInProgress = startInProgress,
                onStart = ::startWatchSource
            )
        }
    }

    override fun onDestroy() {
        bleController.stop()
        healthCaptureController.close()
        healthProbe.close()
        super.onDestroy()
    }

    override fun onStop() {
        // The person must deliberately reopen this tiny source screen before
        // a manual iPhone pull. Do not leave a connectable BLE beacon running
        // while the display/app is no longer foreground; Health Services'
        // passive local recording has its own system registration and keeps
        // collecting independently of this UI.
        bleController.stop()
        startInProgress = false
        if (status.startsWith("已启动") || status.startsWith("正在启动")) {
            status = "连接广播已暂停；本地健康记录仍会由系统低功耗保存。"
        }
        super.onStop()
    }

    private fun startWatchSource() {
        // Update synchronously so a tap never looks ignored while Android is
        // preparing the GATT server or a system permission prompt.
        Log.i(LOG_TAG, "Watch source start requested")
        startInProgress = true
        status = "已收到启动请求，正在准备低功耗连接服务…"
        startRequested = true
        healthStartDispatched = false
        requestBluetoothAndStart()
        healthProbe.refresh()
        ensurePassiveHealthRecordingIfRequested()
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

    private fun ensurePassiveHealthRecordingIfRequested() {
        if (!startRequested || healthStartDispatched || healthPermissionRequestInFlight) return
        // The probe is asynchronous. Waiting for its final snapshot prevents
        // a first Start tap from registering an empty data-type set.
        if (healthCapabilities.status.startsWith("正在检查")) return

        val missingPermissions = healthCaptureController.requiredPermissions().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isEmpty()) {
            healthStartDispatched = true
            healthCaptureController.startAfterPermissionRequest()
        } else {
            healthStartDispatched = true
            healthPermissionRequestInFlight = true
            healthPermissions.launch(missingPermissions.toTypedArray())
        }
    }

    private fun updateStatus(result: BleFoundationResult) {
        startInProgress = result is BleFoundationResult.Starting
        status = when (result) {
            BleFoundationResult.Starting -> "正在启动低功耗 BLE 连接服务…"
            BleFoundationResult.Started -> "已启动。现在可在 iPhone 上连接、配对并手动同步。"
            is BleFoundationResult.Unavailable -> result.reason
        }
    }

    private companion object {
        const val LOG_TAG = "GalaxyCompanion"
    }
}

@Composable
private fun GalaxyCompanionWatchApp(
    bleStatus: String,
    healthCapture: WatchHealthCaptureSnapshot,
    startInProgress: Boolean,
    onStart: () -> Unit
) {
    MaterialTheme {
        // A regular Column clips on small, round Watches. The UI deliberately
        // stays tiny: one action and only the status needed at the source.
        val listState = rememberScalingLazyListState()
        val sourceStarted = bleStatus.startsWith("已启动")
        ScalingLazyColumn(
            modifier = Modifier.fillMaxSize(),
            state = listState,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            item {
                Text(
                    "GalaxyCompanion",
                    modifier = Modifier.padding(top = 10.dp, bottom = 6.dp)
                )
            }
            item {
                Button(
                    onClick = onStart,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp)
                ) {
                    Text(
                        when {
                            startInProgress -> "正在启动…"
                            sourceStarted -> "已启动"
                            else -> "启动"
                        }
                    )
                }
            }
            item {
                Text(
                    bleStatus,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                )
            }
            item {
                Text(
                    "本地缓存 ${healthCapture.storedSampleCount ?: 0} 条 · 仅手动同步时传输",
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                )
            }
            item {
                // Extra bottom space lets the final line clear the system
                // gesture area on devices with a chin or larger insets.
                Text("", modifier = Modifier.padding(bottom = 24.dp))
            }
        }
    }
}
