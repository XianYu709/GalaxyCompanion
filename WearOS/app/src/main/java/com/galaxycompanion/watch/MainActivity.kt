package com.galaxycompanion.watch

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.Text
import com.galaxycompanion.watch.ble.BleFoundationResult
import com.galaxycompanion.watch.ble.WatchBleController

class MainActivity : ComponentActivity() {
    private var status by mutableStateOf("等待启动 GalaxyCompanion BLE 服务")
    private val bleController by lazy {
        WatchBleController(applicationContext) { result ->
            runOnUiThread { updateStatus(result) }
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            GalaxyCompanionWatchApp(
                status = status,
                onStart = ::requestBluetoothAndStart,
                onStop = {
                    bleController.stop()
                    status = "BLE 服务已停止"
                }
            )
        }
    }

    override fun onDestroy() {
        bleController.stop()
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
    onStart: () -> Unit,
    onStop: () -> Unit
) {
    MaterialTheme {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(12.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text("GalaxyCompanion")
            Text("连接验证")
            Spacer(Modifier.height(8.dp))
            Text(status)
            Spacer(Modifier.height(8.dp))
            Button(onClick = onStart) {
                Text("启动 BLE")
            }
            Button(onClick = onStop) {
                Text("停止")
            }
        }
    }
}
