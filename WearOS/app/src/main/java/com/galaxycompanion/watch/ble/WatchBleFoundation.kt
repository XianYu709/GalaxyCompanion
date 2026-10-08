package com.galaxycompanion.watch.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid

sealed interface BleFoundationResult {
    data object Starting : BleFoundationResult
    data object Started : BleFoundationResult
    data class Unavailable(val reason: String) : BleFoundationResult
}

/**
 * Sprint 1 GATT-server foundation. Runtime permissions are intentionally not
 * requested here: the presentation layer must obtain them before calling start.
 */
class WatchGattServer(context: Context) {
    private val applicationContext = context.applicationContext
    private val bluetoothManager = applicationContext.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null

    private val callback = object : BluetoothGattServerCallback() {}

    @SuppressLint("MissingPermission")
    fun start(): BleFoundationResult {
        if (server != null) return BleFoundationResult.Started

        val openedServer = bluetoothManager.openGattServer(applicationContext, callback)
            ?: return BleFoundationResult.Unavailable("无法打开 Bluetooth GATT Server")

        val service = BluetoothGattService(
            GalaxyCompanionGattContract.serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                GalaxyCompanionGattContract.capabilitiesCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
        )
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                GalaxyCompanionGattContract.syncControlCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
        )
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                GalaxyCompanionGattContract.syncDataCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
        )

        if (!openedServer.addService(service)) {
            openedServer.close()
            return BleFoundationResult.Unavailable("无法注册 GalaxyCompanion GATT 服务")
        }

        server = openedServer
        return BleFoundationResult.Started
    }

    fun stop() {
        server?.close()
        server = null
    }
}

class WatchBleAdvertiser(
    context: Context,
    private val onResult: (BleFoundationResult) -> Unit
) {
    private val adapter: BluetoothAdapter? = context.getSystemService(BluetoothManager::class.java).adapter
    private var advertiser: BluetoothLeAdvertiser? = null

    private val callback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            onResult(BleFoundationResult.Started)
        }

        override fun onStartFailure(errorCode: Int) {
            advertiser = null
            onResult(BleFoundationResult.Unavailable("BLE 广播启动失败，错误码：$errorCode"))
        }
    }

    @SuppressLint("MissingPermission")
    fun start(): BleFoundationResult {
        if (advertiser != null) return BleFoundationResult.Started

        val availableAdvertiser = adapter?.bluetoothLeAdvertiser
            ?: return BleFoundationResult.Unavailable("当前手表不支持 BLE 广播")
        if (!adapter.isMultipleAdvertisementSupported) {
            return BleFoundationResult.Unavailable("当前手表不支持可连接的 BLE 广播")
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(GalaxyCompanionGattContract.serviceUuid))
            .setIncludeDeviceName(false)
            .build()

        availableAdvertiser.startAdvertising(settings, data, callback)
        advertiser = availableAdvertiser
        return BleFoundationResult.Starting
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        advertiser?.stopAdvertising(callback)
        advertiser = null
    }
}

class WatchBleController(
    context: Context,
    onAdvertisementResult: (BleFoundationResult) -> Unit
) {
    private val gattServer = WatchGattServer(context)
    private val advertiser = WatchBleAdvertiser(context, onAdvertisementResult)

    fun start(): BleFoundationResult {
        return when (val gattResult = gattServer.start()) {
            is BleFoundationResult.Unavailable -> gattResult
            BleFoundationResult.Started,
            BleFoundationResult.Starting -> advertiser.start()
        }
    }

    fun stop() {
        advertiser.stop()
        gattServer.stop()
    }
}
