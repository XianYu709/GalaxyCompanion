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
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import com.galaxycompanion.watch.health.WatchHealthCapabilitySnapshot
import com.galaxycompanion.watch.health.WatchHealthSampleStore
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
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
    private val healthCapabilities: () -> WatchHealthCapabilitySnapshot,
    private val onServiceResult: (Long, BleFoundationResult) -> Unit,
    private val onManualSyncStatus: (String) -> Unit
) {
    private val applicationContext = context.applicationContext
    private val bluetoothManager = applicationContext.getSystemService(BluetoothManager::class.java)
    private val sampleStore = WatchHealthSampleStore(applicationContext)
    private val manualSyncExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val manualSyncWatchdog = Executors.newSingleThreadScheduledExecutor()
    private var server: BluetoothGattServer? = null
    private var syncDataCharacteristic: BluetoothGattCharacteristic? = null
    private var serviceRegistrationPending = false
    private var lifecycleGeneration = 0L
    private var pendingService: BluetoothGattService? = null
    private var pendingServiceGeneration: Long? = null
    private var registeredServiceGeneration: Long? = null
    private val authenticatedDeviceAddresses = ConcurrentHashMap.newKeySet<String>()
    private val subscribedDeviceAddresses = ConcurrentHashMap.newKeySet<String>()
    private val negotiatedMtuByDevice = ConcurrentHashMap<String, Int>()
    private val pendingNotificationsByDevice = ConcurrentHashMap<String, ArrayDeque<ByteArray>>()
    private val notificationInFlightDevices = ConcurrentHashMap.newKeySet<String>()
    private val manualSyncDeadlineByDevice = ConcurrentHashMap<String, ScheduledFuture<*>>()
    // The iPhone transport permits exactly one outstanding request. Mirror
    // that bound on the GATT server so an authenticated central cannot build
    // an unbounded notification queue with overlapping requests.
    private val syncRequestInFlightDevices = ConcurrentHashMap.newKeySet<String>()
    private val notificationLock = Any()

    /** Current GATT lifecycle generation; callback consumers must match it. */
    val activeGeneration: Long?
        get() = registeredServiceGeneration ?: pendingServiceGeneration

    private fun capabilitiesPayload(forDevice: BluetoothDevice): ByteArray {
        val healthDataMode = if (isAuthenticated(forDevice)) {
            "authenticatedMeasurement"
        } else {
            "unavailable"
        }
        return capabilitiesPayload(healthDataMode)
    }

    private fun capabilitiesPayload(healthDataMode: String): ByteArray {
        val capabilities = healthCapabilities()
        val storage = runCatching { sampleStore.summary() }.getOrNull()
        val recordingEnabled = runCatching { sampleStore.isPassiveCaptureEnabled() }.getOrNull()
        val payload = JSONObject()
            .put(
                "identity",
                JSONObject()
                    .put("model", capabilities.model)
                    .put("wearOSVersion", capabilities.wearOsVersion)
                    .put("firmwareVersion", capabilities.firmwareVersion)
            )
            .put("enabled", org.json.JSONArray().apply {
                capabilities.metricNames.sorted().forEach(::put)
            })
            // Keep this separate from `enabled`: the runtime inventory tells
            // iPhone what Health Services reports, while `enabled` is only
            // the subset this app actually records with a safe wire meaning.
            .put("passiveDataTypeNames", org.json.JSONArray().apply {
                capabilities.passiveDataTypeNames.sorted().forEach(::put)
            })
            // A local collection capability alone is never enough. This
            // value is elevated only after the encrypted pairing gate succeeds
            // for this currently connected central.
            .put("healthDataMode", healthDataMode)
        // This is deliberately count/status only. It makes an empty manual
        // sync explainable without exposing health history in diagnostics.
        storage?.let { payload.put("localHealthSampleCount", it.sampleCount) }
        recordingEnabled?.let { payload.put("isLocalHealthRecordingEnabled", it) }
        return payload.toString().encodeToByteArray()
    }

    private val callback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (
                newState == BluetoothProfile.STATE_CONNECTED ||
                newState == BluetoothProfile.STATE_DISCONNECTED ||
                status != BluetoothGatt.GATT_SUCCESS
            ) {
                authenticatedDeviceAddresses.remove(device.address)
                subscribedDeviceAddresses.remove(device.address)
                negotiatedMtuByDevice.remove(device.address)
                clearPendingNotifications(device.address)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            // Android reports the negotiated ATT MTU here. A notification has
            // a three-byte ATT opcode/handle overhead, per the Bluetooth GATT
            // ATT protocol. Android API: https://developer.android.com/reference/android/bluetooth/BluetoothGattServerCallback#onMtuChanged(android.bluetooth.BluetoothDevice,int)
            negotiatedMtuByDevice[device.address] = mtu.coerceAtLeast(DEFAULT_ATT_MTU)
        }

        @SuppressLint("MissingPermission")
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
                registeredServiceGeneration = null
                onServiceResult(
                    generation,
                    BleFoundationResult.Unavailable("无法注册 GalaxyCompanion GATT 服务，错误码：$status")
                )
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == GalaxyCompanionGattContract.pairingGateCharacteristicUuid) {
                val isBonded = device.bondState == BluetoothDevice.BOND_BONDED
                if (!isBonded) {
                    server?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION,
                        offset,
                        null
                    )
                    return
                }
                val payload = GalaxyCompanionGattContract.pairingGatePayload
                if (offset != 0) {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    return
                }
                val accepted = server?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    payload
                ) == true
                if (accepted) {
                    authenticatedDeviceAddresses += device.address
                }
                return
            }

            if (characteristic.uuid != GalaxyCompanionGattContract.capabilitiesCharacteristicUuid) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

            val payload = capabilitiesPayload(device)
            if (offset > payload.size) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

            server?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                offset,
                payload.copyOfRange(offset, payload.size)
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
            if (characteristic.uuid != GalaxyCompanionGattContract.syncControlCharacteristicUuid ||
                preparedWrite || offset != 0 || !isAuthenticated(device)
            ) {
                if (responseNeeded) {
                    server?.sendResponse(
                        device,
                        requestId,
                        if (isAuthenticated(device)) BluetoothGatt.GATT_FAILURE
                        else BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION,
                        offset,
                        null
                    )
                }
                return
            }

            val request = decodeSyncRequest(value)
            if (request == null || device.address !in subscribedDeviceAddresses) {
                if (responseNeeded) {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                }
                return
            }

            if (!syncRequestInFlightDevices.add(device.address)) {
                if (responseNeeded) {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                }
                return
            }

            if (responseNeeded && server?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    null
                ) != true
            ) {
                clearPendingNotifications(device.address)
                onManualSyncStatus("无法确认 iPhone 的手动同步请求；请保持连接后重试。")
                return
            }

            onManualSyncStatus("已收到 iPhone 手动同步请求；正在准备 Watch 本地缓存。")
            try {
                scheduleManualSyncDeadline(device.address)
                manualSyncExecutor.execute {
                    prepareAndEnqueueManualSync(device, request)
                }
            } catch (error: Exception) {
                clearPendingNotifications(device.address)
                onManualSyncStatus(
                    "无法开始手动同步：" +
                        (error.localizedMessage ?: error.javaClass.simpleName)
                )
            }
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
                    subscribedDeviceAddresses += device.address
                    BluetoothGatt.GATT_SUCCESS
                }
                value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) -> {
                    subscribedDeviceAddresses.remove(device.address)
                    clearPendingNotifications(device.address)
                    BluetoothGatt.GATT_SUCCESS
                }
                else -> BluetoothGatt.GATT_FAILURE
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, status, offset, null)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            synchronized(notificationLock) {
                val address = device.address
                notificationInFlightDevices.remove(address)
                val pending = pendingNotificationsByDevice[address] ?: return
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    clearPendingNotificationsLocked(address)
                    return
                }
                if (pending.isNotEmpty()) {
                    pending.removeFirst()
                }
                if (pending.isEmpty()) {
                    pendingNotificationsByDevice.remove(address)
                    syncRequestInFlightDevices.remove(address)
                } else {
                    sendNextNotificationLocked(device, address, pending)
                }
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
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
        )
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                GalaxyCompanionGattContract.pairingGateCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_READ,
                // Android enforces encrypted/MITM attribute permissions before
                // delivering this request to the server callback. We still
                // verify BOND_BONDED and create a connection-local gate below;
                // neither condition alone is treated as trust. Android API:
                // https://developer.android.com/reference/android/bluetooth/BluetoothGattCharacteristic#PERMISSION_READ_ENCRYPTED_MITM
                BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED_MITM
            )
        )
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                GalaxyCompanionGattContract.syncControlCharacteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED_MITM
            )
        )
        val syncDataCharacteristic = BluetoothGattCharacteristic(
            GalaxyCompanionGattContract.syncDataCharacteristicUuid,
            // The Android Watch6/iPhone pairing can fail a perfectly valid
            // ATT indication with "Peer failed to respond". Send one paced
            // notification at a time instead. If one is missed, the iPhone
            // does not advance its durable cursor and asks for this same page
            // again on the next manual pull.
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
        this.syncDataCharacteristic = syncDataCharacteristic

        val generation = ++lifecycleGeneration
        server = openedServer
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

    @SuppressLint("MissingPermission")
    fun stop() {
        lifecycleGeneration += 1
        server?.close()
        server = null
        serviceRegistrationPending = false
        pendingService = null
        pendingServiceGeneration = null
        registeredServiceGeneration = null
        authenticatedDeviceAddresses.clear()
        subscribedDeviceAddresses.clear()
        negotiatedMtuByDevice.clear()
        pendingNotificationsByDevice.clear()
        notificationInFlightDevices.clear()
        syncRequestInFlightDevices.clear()
        manualSyncDeadlineByDevice.values.forEach { it.cancel(false) }
        manualSyncDeadlineByDevice.clear()
        syncDataCharacteristic = null
    }

    @SuppressLint("MissingPermission")
    private fun isAuthenticated(device: BluetoothDevice): Boolean =
        device.bondState == BluetoothDevice.BOND_BONDED &&
            device.address in authenticatedDeviceAddresses

    @SuppressLint("MissingPermission")
    private fun enqueueNotifications(device: BluetoothDevice, packets: List<ByteArray>): Boolean {
        synchronized(notificationLock) {
            val address = device.address
            if (
                address !in subscribedDeviceAddresses ||
                !isAuthenticated(device) ||
                address !in syncRequestInFlightDevices ||
                pendingNotificationsByDevice.containsKey(address)
            ) return false
            val pending = pendingNotificationsByDevice.getOrPut(address) { ArrayDeque() }
            packets.forEach(pending::addLast)
            if (address !in notificationInFlightDevices) {
                sendNextNotificationLocked(device, address, pending)
            }
            return pendingNotificationsByDevice.containsKey(address)
        }
    }

    @SuppressLint("MissingPermission", "DEPRECATION")
    @Suppress("DEPRECATION")
    private fun sendNextNotificationLocked(
        device: BluetoothDevice,
        address: String,
        pending: ArrayDeque<ByteArray>
    ) {
        if (pending.isEmpty() || address in notificationInFlightDevices) return
        val characteristic = syncDataCharacteristic ?: run {
            // This is a terminal transport failure for this central. Clear
            // every per-request marker as well as the packets, otherwise a
            // later control write could be permanently rejected as "in
            // flight" after the characteristic has gone away.
            clearPendingNotificationsLocked(address)
            return
        }
        // API 33 accepts an immutable value for this one notification. That
        // avoids sharing characteristic.value between concurrent centrals.
        // The deprecated fallback is kept for Wear OS devices below API 33.
        val notificationQueued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server?.notifyCharacteristicChanged(device, characteristic, false, pending.first) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            characteristic.value = pending.first
            server?.notifyCharacteristicChanged(device, characteristic, false) == true
        }
        if (notificationQueued) {
            notificationInFlightDevices += address
        } else {
            clearPendingNotificationsLocked(address)
        }
    }

    private fun clearPendingNotifications(address: String) = synchronized(notificationLock) {
        clearPendingNotificationsLocked(address)
    }

    private fun clearPendingNotificationsLocked(address: String) {
        pendingNotificationsByDevice.remove(address)?.clear()
        notificationInFlightDevices.remove(address)
        syncRequestInFlightDevices.remove(address)
        manualSyncDeadlineByDevice.remove(address)?.cancel(false)
    }

    @SuppressLint("MissingPermission")
    private fun prepareAndEnqueueManualSync(device: BluetoothDevice, request: SyncRequest) {
        try {
            val preparedResponse = packetsForRequest(device, request)
            if (!enqueueNotifications(device, preparedResponse.packets)) {
                clearPendingNotifications(device.address)
                onManualSyncStatus("无法将手动同步结果送入 BLE 通知队列；请保持连接后重试。")
                return
            }
            onManualSyncStatus(manualSyncStatusFor(preparedResponse))
        } catch (error: Exception) {
            // The Watch cursor is never acknowledged or advanced by a
            // request. A failed response can be retried by the phone.
            clearPendingNotifications(device.address)
            onManualSyncStatus(
                "处理 iPhone 手动同步失败：" +
                    (error.localizedMessage ?: error.javaClass.simpleName)
            )
        }
    }

    private fun manualSyncStatusFor(response: PreparedSyncResponse): String {
        return if (response.sampleCount == 0) {
            "iPhone 已请求手动同步；Watch 本地当前没有可回传的健康记录。"
        } else {
            "iPhone 已请求手动同步；正在回传本页 ${response.sampleCount} 条本地健康记录。"
        }
    }

    private fun scheduleManualSyncDeadline(address: String) {
        manualSyncDeadlineByDevice.remove(address)?.cancel(false)
        val deadline = manualSyncWatchdog.schedule({
            synchronized(notificationLock) {
                if (address !in syncRequestInFlightDevices) return@schedule
                clearPendingNotificationsLocked(address)
            }
            onManualSyncStatus("本次手动同步在确认回传前超时；iPhone 可重新同步。")
        }, MANUAL_SYNC_DEADLINE_SECONDS, TimeUnit.SECONDS)
        manualSyncDeadlineByDevice[address] = deadline
    }

    /**
     * Selects a page that fits the actual negotiated ATT payload. At the
     * default MTU this can be fewer than the protocol's 20-sample maximum;
     * the phone follows the returned cursor and requests the next page. No
     * record is deleted or cursor acknowledged while reducing the page size.
     */
    private fun packetsForRequest(
        device: BluetoothDevice,
        request: SyncRequest
    ): PreparedSyncResponse {
        var candidateMaximum = request.maximumSampleCount
        while (true) {
            val batch = sampleStore.nextBatch(
                requestID = request.requestID,
                afterCursor = request.afterCursor,
                maximumSampleCount = candidateMaximum
            )
            try {
                val packets = GATTHealthSyncPacketCodec.fragment(
                    payload = batch.payload,
                    protocolVersion = GalaxyCompanionGattContract.protocolVersion,
                    sequence = batch.sequence,
                    maximumPacketSize = notificationPacketSize(device.address)
                )
                return PreparedSyncResponse(packets, batch.sampleCount)
            } catch (error: IllegalArgumentException) {
                // Failure envelopes are already the smallest valid recovery
                // response. A single sample that cannot fit must surface as a
                // request failure rather than silently skipping it.
                if (batch.isRemoteFailure || batch.sampleCount <= 1) throw error
                candidateMaximum = minOf(
                    batch.sampleCount - 1,
                    maxOf(1, candidateMaximum / 2)
                )
            }
        }
    }

    private fun notificationPacketSize(address: String): Int {
        val mtu = negotiatedMtuByDevice[address] ?: DEFAULT_ATT_MTU
        return (mtu - ATT_PROTOCOL_OVERHEAD).coerceIn(
            GATTHealthSyncPacketCodec.headerLength + 1,
            GATTHealthSyncPacketCodec.headerLength + GATTHealthSyncPacketCodec.maximumFragmentPayloadBytes
        )
    }

    private fun decodeSyncRequest(value: ByteArray): SyncRequest? = try {
        val json = JSONObject(value.decodeToString())
        val protocolVersion = json.getInt("protocolVersion")
        val requestID = UUID.fromString(json.getString("requestID")).toString()
        val afterCursor = json.getLong("afterCursor")
        val maximumSampleCount = json.getInt("maximumSampleCount")
        if (
            protocolVersion != GalaxyCompanionGattContract.protocolVersion ||
            afterCursor < 0L ||
            maximumSampleCount !in 1..MAXIMUM_REQUESTED_SAMPLE_COUNT
        ) {
            null
        } else {
            SyncRequest(requestID, afterCursor, maximumSampleCount)
        }
    } catch (_: Exception) {
        null
    }

    private data class SyncRequest(
        val requestID: String,
        val afterCursor: Long,
        val maximumSampleCount: Int
    )

    private data class PreparedSyncResponse(
        val packets: List<ByteArray>,
        val sampleCount: Int
    )

    private companion object {
        const val DEFAULT_ATT_MTU = 23
        const val ATT_PROTOCOL_OVERHEAD = 3
        const val MAXIMUM_REQUESTED_SAMPLE_COUNT = 20
        const val MANUAL_SYNC_DEADLINE_SECONDS = 20L
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
            // Discovery is user initiated from the foreground Watch screen.
            // Prefer the lowest-power interval over keeping a fast beacon
            // alive for a feature that has no realtime requirement.
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
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
    healthCapabilities: () -> WatchHealthCapabilitySnapshot,
    private val onAdvertisementResult: (BleFoundationResult) -> Unit,
    onManualSyncStatus: (String) -> Unit
) {
    private val advertiser = WatchBleAdvertiser(context, onAdvertisementResult)
    private val gattServer = WatchGattServer(
        context,
        healthCapabilities,
        ::handleGattServiceResult,
        onManualSyncStatus
    )
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
