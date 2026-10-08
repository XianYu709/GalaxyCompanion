package com.galaxycompanion.watch.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import com.galaxycompanion.watch.BuildConfig
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.UUID

sealed interface BleFoundationResult {
    data object Starting : BleFoundationResult
    data object Started : BleFoundationResult
    data class Unavailable(val reason: String) : BleFoundationResult
}

/**
 * Sprint 1 GATT-server foundation. Runtime permissions are intentionally not
 * requested here: the presentation layer must obtain them before calling start.
 */
class WatchGattServer(
    context: Context,
    private val onServiceResult: (Long, BleFoundationResult) -> Unit
) {
    private val applicationContext = context.applicationContext
    private val bluetoothManager = applicationContext.getSystemService(BluetoothManager::class.java)
    private val demoHealthStore = WatchDemoHealthSampleStore(applicationContext)
    private var server: BluetoothGattServer? = null
    private var syncDataCharacteristic: BluetoothGattCharacteristic? = null
    private var serviceRegistrationPending = false
    private var lifecycleGeneration = 0L
    private var pendingService: BluetoothGattService? = null
    private var pendingServiceGeneration: Long? = null
    private var registeredServiceGeneration: Long? = null
    private val subscribedDevices = mutableSetOf<String>()
    private val negotiatedMtuByDevice = mutableMapOf<String, Int>()
    private val pendingNotifications = mutableMapOf<String, ArrayDeque<ByteArray>>()

    /** Current GATT lifecycle generation; callback consumers must match it. */
    val activeGeneration: Long?
        get() = registeredServiceGeneration ?: pendingServiceGeneration

    private val capabilitiesPayload: ByteArray
        get() = JSONObject()
            .put(
                "identity",
                JSONObject()
                    .put("model", if (BuildConfig.DEBUG) "GalaxyCompanion Development Watch" else "GalaxyCompanion Watch")
                    .put("wearOSVersion", "Wear OS")
                    .put("firmwareVersion", if (BuildConfig.DEBUG) "0.1.0-debug" else "0.1.0")
            )
            .put("enabled", org.json.JSONArray().apply {
                put("heartRate")
                put("steps")
                put("calories")
                put("distance")
            })
            .put(
                "healthDataMode",
                if (BuildConfig.DEBUG) "developmentSynthetic" else "unavailable"
            )
            .toString()
            .encodeToByteArray()

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            val generation = pendingServiceGeneration
            // Android delivers this asynchronously and provides no generation
            // token. Identity plus our lifecycle state safely rejects a stale
            // callback from a stopped/restarted server.
            if (
                service.uuid != GalaxyCompanionGattContract.serviceUuid ||
                server == null ||
                pendingService !== service ||
                generation == null
            ) return

            serviceRegistrationPending = false
            pendingService = null
            pendingServiceGeneration = null
            if (status == BluetoothGatt.GATT_SUCCESS) {
                registeredServiceGeneration = generation
                onServiceResult(generation, BleFoundationResult.Started)
            } else {
                server?.close()
                server = null
                syncDataCharacteristic = null
                registeredServiceGeneration = null
                onServiceResult(
                    generation,
                    BleFoundationResult.Unavailable("无法注册 GalaxyCompanion GATT 服务，错误码：$status")
                )
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedDevices.remove(device.address)
                negotiatedMtuByDevice.remove(device.address)
                pendingNotifications.remove(device.address)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            negotiatedMtuByDevice[device.address] = mtu
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != GalaxyCompanionGattContract.capabilitiesCharacteristicUuid) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

            if (offset > capabilitiesPayload.size) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

            server?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                offset,
                capabilitiesPayload.copyOfRange(offset, capabilitiesPayload.size)
            )
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            // There is no authenticated pairing/session design yet. Debug
            // builds may emit synthetic fixtures solely for protocol testing;
            // release builds always fail closed and never transfer health data.
            if (!BuildConfig.DEBUG) {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }
            if (
                characteristic.uuid != GalaxyCompanionGattContract.syncControlCharacteristicUuid ||
                preparedWrite ||
                offset != 0
            ) {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }

            val request = decodeSyncRequest(value)
            if (request == null) {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }
            if (device.address !in subscribedDevices) {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }
            if (!pendingNotifications[device.address].isNullOrEmpty()) {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }

            val batch = demoHealthStore.nextBatch(
                requestId = request.requestId,
                afterCursor = request.afterCursor,
                requestedMaximumSampleCount = request.maximumSampleCount
            ) ?: run {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }
            val batchJson = demoHealthStore.encodeBatch(batch)
            val maximumPacketSize = ((negotiatedMtuByDevice[device.address] ?: DEFAULT_ATT_MTU) - ATT_PROTOCOL_OVERHEAD)
                .coerceAtLeast(GATTHealthSyncPacketCodec.headerLength + 1)
            val packets = try {
                GATTHealthSyncPacketCodec.fragment(
                    payload = batchJson,
                    protocolVersion = batch.protocolVersion,
                    sequence = batch.sequence,
                    maximumPacketSize = maximumPacketSize
                )
            } catch (_: IllegalArgumentException) {
                respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_FAILURE)
                return
            }

            respondToWriteIfNeeded(device, requestId, responseNeeded, BluetoothGatt.GATT_SUCCESS)
            pendingNotifications[device.address] = ArrayDeque(packets)
            sendNextNotification(device)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            val isSyncDataSubscription = descriptor.uuid == CLIENT_CHARACTERISTIC_CONFIGURATION_UUID &&
                descriptor.characteristic.uuid == GalaxyCompanionGattContract.syncDataCharacteristicUuid &&
                !preparedWrite && offset == 0
            val status = when {
                !isSyncDataSubscription -> BluetoothGatt.GATT_FAILURE
                value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) -> {
                    subscribedDevices.add(device.address)
                    BluetoothGatt.GATT_SUCCESS
                }
                value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) -> {
                    subscribedDevices.remove(device.address)
                    pendingNotifications.remove(device.address)
                    BluetoothGatt.GATT_SUCCESS
                }
                else -> BluetoothGatt.GATT_FAILURE
            }
            respondToWriteIfNeeded(device, requestId, responseNeeded, status)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                sendNextNotification(device)
            } else {
                pendingNotifications.remove(device.address)
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun start(): BleFoundationResult {
        if (server != null) {
            return if (serviceRegistrationPending) BleFoundationResult.Starting else BleFoundationResult.Started
        }

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
        val syncDataCharacteristic = BluetoothGattCharacteristic(
            GalaxyCompanionGattContract.syncDataCharacteristicUuid,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        syncDataCharacteristic.addDescriptor(
            BluetoothGattDescriptor(
                CLIENT_CHARACTERISTIC_CONFIGURATION_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
        )
        service.addCharacteristic(syncDataCharacteristic)

        val generation = ++lifecycleGeneration
        server = openedServer
        this.syncDataCharacteristic = syncDataCharacteristic
        serviceRegistrationPending = true
        pendingService = service
        pendingServiceGeneration = generation
        registeredServiceGeneration = null
        if (!openedServer.addService(service)) {
            openedServer.close()
            server = null
            this.syncDataCharacteristic = null
            serviceRegistrationPending = false
            pendingService = null
            pendingServiceGeneration = null
            return BleFoundationResult.Unavailable("无法注册 GalaxyCompanion GATT 服务")
        }

        return BleFoundationResult.Starting
    }

    fun stop() {
        lifecycleGeneration += 1
        server?.close()
        server = null
        syncDataCharacteristic = null
        serviceRegistrationPending = false
        pendingService = null
        pendingServiceGeneration = null
        registeredServiceGeneration = null
        subscribedDevices.clear()
        negotiatedMtuByDevice.clear()
        pendingNotifications.clear()
    }

    @SuppressLint("MissingPermission")
    private fun respondToWriteIfNeeded(
        device: BluetoothDevice,
        requestId: Int,
        responseNeeded: Boolean,
        status: Int
    ) {
        if (responseNeeded) {
            server?.sendResponse(device, requestId, status, 0, null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendNextNotification(device: BluetoothDevice) {
        val queue = pendingNotifications[device.address] ?: return
        val packet = queue.pollFirst()
        if (packet == null) {
            pendingNotifications.remove(device.address)
            return
        }
        val characteristic = syncDataCharacteristic
        if (characteristic == null || server == null) {
            pendingNotifications.remove(device.address)
            return
        }

        val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server?.notifyCharacteristicChanged(device, characteristic, false, packet)
                ?: BluetoothGatt.GATT_FAILURE
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.value = packet
                if (server?.notifyCharacteristicChanged(device, characteristic, false) == true) {
                    BluetoothGatt.GATT_SUCCESS
                } else {
                    BluetoothGatt.GATT_FAILURE
                }
            }
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            pendingNotifications.remove(device.address)
        }
    }

    private fun decodeSyncRequest(value: ByteArray): SyncRequest? = try {
        val json = JSONObject(value.decodeToString())
            val protocolVersion = json.getInt("protocolVersion")
            val requestId = UUID.fromString(json.getString("requestID")).toString()
        val afterCursor = json.getLong("afterCursor")
        val maximumSampleCount = json.getInt("maximumSampleCount")
        if (
            protocolVersion != GalaxyCompanionGattContract.protocolVersion ||
            afterCursor < 0 ||
            maximumSampleCount !in 1..MAXIMUM_REQUESTED_SAMPLE_COUNT
        ) {
            null
        } else {
            SyncRequest(requestId, afterCursor, maximumSampleCount)
        }
    } catch (_: Exception) {
        null
    }

    private data class SyncRequest(
        val requestId: String,
        val afterCursor: Long,
        val maximumSampleCount: Int
    )

    private companion object {
        const val DEFAULT_ATT_MTU = 23
        const val ATT_PROTOCOL_OVERHEAD = 3
        const val MAXIMUM_REQUESTED_SAMPLE_COUNT = 20
        val CLIENT_CHARACTERISTIC_CONFIGURATION_UUID: java.util.UUID = java.util.UUID.fromString(
            "00002902-0000-1000-8000-00805f9b34fb"
        )
    }
}

class WatchBleAdvertiser(
    context: Context,
    private val onResult: (BleFoundationResult) -> Unit
) {
    private val adapter: BluetoothAdapter? = context.getSystemService(BluetoothManager::class.java).adapter
    private var advertiser: BluetoothLeAdvertiser? = null
    private var callback: AdvertiseCallback? = null
    private var lifecycleGeneration = 0L
    private var advertisingStarted = false

    @SuppressLint("MissingPermission")
    fun start(): BleFoundationResult {
        if (advertiser != null) {
            return if (advertisingStarted) BleFoundationResult.Started else BleFoundationResult.Starting
        }

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

        val generation = ++lifecycleGeneration
        val startCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                if (generation != lifecycleGeneration || callback !== this) return
                advertisingStarted = true
                onResult(BleFoundationResult.Started)
            }

            override fun onStartFailure(errorCode: Int) {
                if (generation != lifecycleGeneration || callback !== this) return
                advertiser = null
                callback = null
                advertisingStarted = false
                onResult(BleFoundationResult.Unavailable("BLE 广播启动失败，错误码：$errorCode"))
            }
        }
        callback = startCallback
        advertisingStarted = false
        availableAdvertiser.startAdvertising(settings, data, startCallback)
        advertiser = availableAdvertiser
        return BleFoundationResult.Starting
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        lifecycleGeneration += 1
        callback?.let { advertiser?.stopAdvertising(it) }
        advertiser = null
        callback = null
        advertisingStarted = false
    }
}

class WatchBleController(
    context: Context,
    private val onAdvertisementResult: (BleFoundationResult) -> Unit
) {
    private val advertiser = WatchBleAdvertiser(context, onAdvertisementResult)
    private val gattServer = WatchGattServer(context, ::handleGattServiceResult)
    private var shouldAdvertise = false
    private var expectedGattGeneration: Long? = null

    fun start(): BleFoundationResult {
        shouldAdvertise = true
        val gattResult = gattServer.start()
        expectedGattGeneration = gattServer.activeGeneration
        return when (gattResult) {
            is BleFoundationResult.Unavailable -> {
                shouldAdvertise = false
                expectedGattGeneration = null
                gattResult
            }
            BleFoundationResult.Started -> advertiser.start()
            BleFoundationResult.Starting -> BleFoundationResult.Starting
        }
    }

    fun stop() {
        shouldAdvertise = false
        expectedGattGeneration = null
        advertiser.stop()
        gattServer.stop()
    }

    private fun handleGattServiceResult(generation: Long, result: BleFoundationResult) {
        if (!shouldAdvertise) return
        // A platform callback can race the return from start(). Accept it only
        // if it still matches the GATT server's active generation; this cannot
        // resurrect an older stopped server.
        if (expectedGattGeneration == null && gattServer.activeGeneration == generation) {
            expectedGattGeneration = generation
        }
        if (generation != expectedGattGeneration) return
        when (result) {
            BleFoundationResult.Started -> onAdvertisementResult(advertiser.start())
            BleFoundationResult.Starting -> onAdvertisementResult(result)
            is BleFoundationResult.Unavailable -> onAdvertisementResult(result)
        }
    }
}
