package com.the356company.sendsnap

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.ConcurrentHashMap

/**
 * Native Android Bluetooth Low Energy (BLE) discovery beacon.
 * Broadcasts Wi-Fi Direct / LocalOnlyHotspot credentials in compact legacy
 * 31-byte BLE service-data packets so nearby Android devices discover and
 * auto-pair cleanly without a shared Wi-Fi router or manual hotspot.
 */
class BleDiscoveryManager(private val context: Context) {

    companion object {
        private const val TAG = "SendSnapBLE"
        private val ADV_SERVICE_UUID = ParcelUuid.fromString("0000FE55-0000-1000-8000-00805F9B34FB")
        private val SCAN_RESP_UUID = ParcelUuid.fromString("0000FE56-0000-1000-8000-00805F9B34FB")
        private const val SENDSNAP_COMPANY_ID = 0x3560
        private const val DIRECT_PREFIX = "DIRECT-S5-Snap"
        private const val DEFAULT_GO_IP = "192.168.49.1"
        private const val FORMAT_COMPACT_DIRECT: Byte = 0x01
        private const val FORMAT_GENERIC_HOTSPOT: Byte = 0x02
        private const val FORMAT_COMPACT_V3_ANDROID: Byte = 0x31
        private const val FORMAT_COMPACT_V3_WINDOWS: Byte = 0x32
        private const val FORMAT_GENERIC_V3_WINDOWS: Byte = 0x34
        private const val EMIT_THROTTLE_MS = 2500L
        private val HEX_CHARS = "0123456789abcdef".toCharArray()
    }

    private val bluetoothAdapter: BluetoothAdapter? =
        (context.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var receiverRegistered = false
    private var isAdvertising = false
    private var isScanning = false
    private var wantsAdvertise = false
    private var wantsScan = false
    private var isPassiveScan = false
    private var activeScanMode: Int = -1

    // Pending advertise parameters (used to auto-resume when Bluetooth turns ON)
    private var advDeviceId: String = ""
    private var advDeviceName: String = "SendSnap Device"
    private var advPort: Int = 53318
    private var advSsid: String = ""
    private var advPassphrase: String = ""
    private var advGoIp: String = DEFAULT_GO_IP

    private val lastEmittedAt = ConcurrentHashMap<String, Long>()

    var onPeerFound: ((Map<String, Any>) -> Unit)? = null

    private val btStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            when (state) {
                BluetoothAdapter.STATE_OFF, BluetoothAdapter.STATE_TURNING_OFF -> {
                    isAdvertising = false
                    isScanning = false
                    activeScanMode = -1
                }
                BluetoothAdapter.STATE_ON -> {
                    if (wantsAdvertise && advSsid.isNotEmpty() && advPassphrase.isNotEmpty()) {
                        startAdvertisingInternal()
                    }
                    if (wantsScan && !isScanning) {
                        startScanningInternal(isPassiveScan)
                    }
                }
            }
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdvertising = true
            Log.d(TAG, "BLE advertising started ($advSsid)")
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            Log.w(TAG, "BLE advertising failed error=$errorCode")
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            handleScanResult(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>?) {
            results?.forEach { handleScanResult(it) }
        }

        override fun onScanFailed(errorCode: Int) {
            isScanning = false
            activeScanMode = -1
            Log.w(TAG, "BLE scan failed error=$errorCode")
        }
    }

    init {
        registerStateReceiver()
    }

    private fun registerStateReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        try {
            ContextCompat.registerReceiver(
                context.applicationContext,
                btStateReceiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            receiverRegistered = true
        } catch (e: Exception) {
            Log.w(TAG, "registerStateReceiver note: ${e.message}")
        }
    }

    fun isBluetoothEnabled(): Boolean {
        return try {
            bluetoothAdapter?.isEnabled == true
        } catch (_: Exception) {
            false
        }
    }

    fun hasAdvertisePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_ADVERTISE
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH
            ) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_ADMIN
                ) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun hasScanPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
        }
    }

    @SuppressLint("MissingPermission")
    fun startAdvertising(
        deviceId: String,
        deviceName: String,
        port: Int,
        ssid: String,
        passphrase: String,
        goIp: String
    ) {
        advDeviceId = deviceId
        advDeviceName = deviceName.ifBlank { "SendSnap Device" }
        advPort = port
        advSsid = ssid
        advPassphrase = passphrase
        advGoIp = goIp.ifBlank { DEFAULT_GO_IP }
        wantsAdvertise = ssid.isNotEmpty() && passphrase.isNotEmpty()

        stopAdvertiseInternal()
        if (!wantsAdvertise) return
        startAdvertisingInternal()
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertisingInternal() {
        if (!wantsAdvertise || advSsid.isEmpty() || advPassphrase.isEmpty()) return
        if (!isBluetoothEnabled() || !hasAdvertisePermission()) return
        val advertiser = bluetoothAdapter?.bluetoothLeAdvertiser ?: return

        val isCompactDirect = advSsid.startsWith(DIRECT_PREFIX) &&
            advSsid.length == DIRECT_PREFIX.length + 4 &&
            advPassphrase.length == 8 &&
            advGoIp == DEFAULT_GO_IP

        val advPayload: ByteArray
        val scanRespPayload: ByteArray
        val idBytes = parseDeviceId6Bytes(advDeviceId)

        if (isCompactDirect) {
            val suffixBytes = advSsid.substring(DIRECT_PREFIX.length).toByteArray(Charsets.US_ASCII)
            val passBytes = advPassphrase.toByteArray(Charsets.US_ASCII)
            if (suffixBytes.size != 4 || passBytes.size != 8) {
                val (genericAdv, genericResp) = buildFormat02Payloads(idBytes) ?: return
                advPayload = genericAdv
                scanRespPayload = genericResp
            } else {
                advPayload = ByteArray(21)
                advPayload[0] = FORMAT_COMPACT_DIRECT
                System.arraycopy(suffixBytes, 0, advPayload, 1, 4)
                System.arraycopy(passBytes, 0, advPayload, 5, 8)
                advPayload[13] = ((advPort ushr 8) and 0xFF).toByte()
                advPayload[14] = (advPort and 0xFF).toByte()
                System.arraycopy(idBytes, 0, advPayload, 15, 6)

                val nameBytes = truncateUtf8(advDeviceName, 20)
                scanRespPayload = ByteArray(1 + nameBytes.size)
                scanRespPayload[0] = FORMAT_COMPACT_DIRECT
                System.arraycopy(nameBytes, 0, scanRespPayload, 1, nameBytes.size)
            }
        } else {
            val (genericAdv, genericResp) = buildFormat02Payloads(idBytes) ?: return
            advPayload = genericAdv
            scanRespPayload = genericResp
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        val advData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(ADV_SERVICE_UUID, advPayload)
            .build()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(SCAN_RESP_UUID, scanRespPayload)
            .build()

        try {
            advertiser.startAdvertising(settings, advData, scanResponse, advertiseCallback)
        } catch (e: Exception) {
            isAdvertising = false
            Log.w(TAG, "startAdvertising error: ${e.message}")
        }
    }

    private fun buildFormat02Payloads(idBytes: ByteArray): Pair<ByteArray, ByteArray>? {
        val ssidBytes = advSsid.toByteArray(Charsets.UTF_8)
        val passBytes = advPassphrase.toByteArray(Charsets.UTF_8)
        if (ssidBytes.size > 18 || passBytes.size > 19) {
            Log.w(
                TAG,
                "Skipping BLE Format 02 advertising: credentials exceed 18/19 bytes (ssid=${ssidBytes.size}, pass=${passBytes.size})"
            )
            return null
        }

        val (o3, o4) = parseIpLastTwoOctets(advGoIp)

        val advPayload = ByteArray(6 + ssidBytes.size)
        advPayload[0] = FORMAT_GENERIC_HOTSPOT
        advPayload[1] = ((advPort ushr 8) and 0xFF).toByte()
        advPayload[2] = (advPort and 0xFF).toByte()
        advPayload[3] = (o3 and 0xFF).toByte()
        advPayload[4] = (o4 and 0xFF).toByte()
        advPayload[5] = (ssidBytes.size and 0xFF).toByte()
        System.arraycopy(ssidBytes, 0, advPayload, 6, ssidBytes.size)

        val scanRespPayload = ByteArray(8 + passBytes.size)
        scanRespPayload[0] = FORMAT_GENERIC_HOTSPOT
        System.arraycopy(idBytes, 0, scanRespPayload, 1, 6)
        scanRespPayload[7] = (passBytes.size and 0xFF).toByte()
        System.arraycopy(passBytes, 0, scanRespPayload, 8, passBytes.size)

        return advPayload to scanRespPayload
    }

    fun stopAdvertising() {
        wantsAdvertise = false
        advSsid = ""
        advPassphrase = ""
        stopAdvertiseInternal()
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertiseInternal() {
        val advertiser = try {
            bluetoothAdapter?.bluetoothLeAdvertiser
        } catch (_: Exception) {
            null
        }
        if (advertiser != null && isAdvertising) {
            try {
                advertiser.stopAdvertising(advertiseCallback)
            } catch (e: Exception) {
                Log.w(TAG, "stopAdvertising note: ${e.message}")
            }
        }
        isAdvertising = false
    }

    @SuppressLint("MissingPermission")
    fun startScanning(isPassive: Boolean) {
        wantsScan = true
        isPassiveScan = isPassive
        startScanningInternal(isPassive)
    }

    @SuppressLint("MissingPermission")
    fun setScanPace(isPassive: Boolean) {
        isPassiveScan = isPassive
        if (!wantsScan) return
        val desiredMode = if (isPassive) {
            ScanSettings.SCAN_MODE_BALANCED
        } else {
            ScanSettings.SCAN_MODE_LOW_LATENCY
        }
        if (!isScanning || activeScanMode != desiredMode) {
            startScanningInternal(isPassive)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScanningInternal(isPassive: Boolean) {
        if (!wantsScan) return
        if (!isBluetoothEnabled() || !hasScanPermission()) return
        val scanner = bluetoothAdapter?.bluetoothLeScanner ?: return

        val desiredMode = if (isPassive) {
            ScanSettings.SCAN_MODE_BALANCED
        } else {
            ScanSettings.SCAN_MODE_LOW_LATENCY
        }
        if (isScanning && activeScanMode == desiredMode) return

        stopScanInternal()

        val settings = ScanSettings.Builder()
            .setScanMode(desiredMode)
            .setReportDelay(0L)
            .build()

        try {
            scanner.startScan(null, settings, scanCallback)
            isScanning = true
            activeScanMode = desiredMode
            Log.d(TAG, "BLE scan started (passive=$isPassive)")
        } catch (e: Exception) {
            isScanning = false
            activeScanMode = -1
            Log.w(TAG, "startScanning error: ${e.message}")
        }
    }

    fun stopScanning() {
        wantsScan = false
        lastEmittedAt.clear()
        stopScanInternal()
    }

    @SuppressLint("MissingPermission")
    private fun stopScanInternal() {
        val scanner = try {
            bluetoothAdapter?.bluetoothLeScanner
        } catch (_: Exception) {
            null
        }
        if (scanner != null && isScanning) {
            try {
                scanner.stopScan(scanCallback)
            } catch (e: Exception) {
                Log.w(TAG, "stopScan note: ${e.message}")
            }
        }
        isScanning = false
        activeScanMode = -1
    }

    private fun handleScanResult(result: ScanResult) {
        val record = result.scanRecord ?: return

        // 1. Check single-frame ManufacturerSpecificData (0x3560) used by Windows & cross-platform v3 beacons
        val mfg = record.getManufacturerSpecificData(SENDSNAP_COMPANY_ID)
        if (mfg != null && mfg.isNotEmpty()) {
            val mfgPeer = decodeMfgPayload(mfg, record.deviceName)
            if (mfgPeer != null) {
                emitPeerThrottled(mfgPeer)
                return
            }
        }

        // 2. Check legacy/Android 16-bit ServiceData (0xFE55 + 0xFE56)
        val adv = record.getServiceData(ADV_SERVICE_UUID) ?: return
        if (adv.isEmpty()) return
        val resp = record.getServiceData(SCAN_RESP_UUID)

        val peerMap = when (adv[0]) {
            FORMAT_COMPACT_DIRECT -> decodeFormat01(adv, resp)
            FORMAT_GENERIC_HOTSPOT -> decodeFormat02(adv, resp)
            else -> null
        } ?: return

        emitPeerThrottled(peerMap)
    }

    private fun emitPeerThrottled(peerMap: Map<String, Any>) {
        val peerId = peerMap["id"] as? String ?: return
        val now = SystemClock.elapsedRealtime()
        val prev = lastEmittedAt[peerId]
        if (prev != null && now - prev < EMIT_THROTTLE_MS) {
            return
        }
        lastEmittedAt[peerId] = now
        onPeerFound?.invoke(peerMap)
    }

    private fun decodeMfgPayload(mfg: ByteArray, scanDeviceName: String?): Map<String, Any>? {
        if (mfg.isEmpty()) return null
        val tag = mfg[0]
        if ((tag == FORMAT_COMPACT_V3_ANDROID || tag == FORMAT_COMPACT_V3_WINDOWS) && mfg.size >= 23) {
            val suffix = String(mfg, 1, 4, Charsets.US_ASCII)
            val pass = String(mfg, 5, 8, Charsets.US_ASCII)
            if (!suffix.all { it in '0'..'9' || it in 'A'..'Z' || it in 'a'..'z' }) return null
            if (pass.length != 8 || !pass.all { it in '!'..'~' }) return null
            val port = ((mfg[13].toInt() and 0xFF) shl 8) or (mfg[14].toInt() and 0xFF)
            if (port <= 0) return null
            val o3 = mfg[15].toInt() and 0xFF
            val o4 = mfg[16].toInt() and 0xFF
            val hex12 = bytesToHex(mfg, 17, 6)
            val isWindows = tag == FORMAT_COMPACT_V3_WINDOWS
            val cleanScanName = scanDeviceName?.trim()?.takeIf { it.isNotEmpty() }
            val name = cleanScanName ?: if (isWindows) "Windows PC" else "SendSnap Device"

            return mapOf(
                "id" to "ble-$hex12",
                "name" to name,
                "port" to port,
                "deviceType" to if (isWindows) "windows" else "android",
                "p2pDeviceAddress" to "",
                "p2pSsid" to "$DIRECT_PREFIX$suffix",
                "p2pPassphrase" to pass,
                "p2pGoIp" to "192.168.$o3.$o4",
                "airToken" to ""
            )
        }

        if (tag == FORMAT_GENERIC_V3_WINDOWS && mfg.size >= 14) {
            val ssidLen = mfg[1].toInt() and 0xFF
            if (ssidLen <= 0 || ssidLen > 16 || mfg.size < 2 + ssidLen + 12) return null
            val ssid = String(mfg, 2, ssidLen, Charsets.UTF_8)
            val off = 2 + ssidLen
            val pass = String(mfg, off, 8, Charsets.UTF_8)
            val port = ((mfg[off + 8].toInt() and 0xFF) shl 8) or (mfg[off + 9].toInt() and 0xFF)
            if (port <= 0) return null
            val o3 = mfg[off + 10].toInt() and 0xFF
            val o4 = mfg[off + 11].toInt() and 0xFF
            val cleanScanName = scanDeviceName?.trim()?.takeIf { it.isNotEmpty() }

            return mapOf(
                "id" to "ble-$ssid",
                "name" to (cleanScanName ?: "Windows PC"),
                "port" to port,
                "deviceType" to "windows",
                "p2pDeviceAddress" to "",
                "p2pSsid" to ssid,
                "p2pPassphrase" to pass,
                "p2pGoIp" to "192.168.$o3.$o4",
                "airToken" to ""
            )
        }

        return null
    }

    private fun decodeFormat01(adv: ByteArray, resp: ByteArray?): Map<String, Any>? {
        if (adv.size < 21) return null
        val suffix = String(adv, 1, 4, Charsets.US_ASCII)
        val pass = String(adv, 5, 8, Charsets.US_ASCII)
        if (!suffix.all { it in '0'..'9' || it in 'A'..'Z' || it in 'a'..'z' }) return null
        if (pass.length != 8 || !pass.all { it in '!'..'~' }) return null
        val port = ((adv[13].toInt() and 0xFF) shl 8) or (adv[14].toInt() and 0xFF)
        if (port <= 0) return null
        val hex12 = bytesToHex(adv, 15, 6)
        val ssid = "$DIRECT_PREFIX$suffix"

        var name = "SendSnap Device"
        if (resp != null && resp.size > 1 && resp[0] == FORMAT_COMPACT_DIRECT) {
            val decoded = String(resp, 1, resp.size - 1, Charsets.UTF_8).trim()
            if (decoded.isNotEmpty()) {
                name = decoded
            }
        }

        return mapOf(
            "id" to "ble-$hex12",
            "name" to name,
            "port" to port,
            "deviceType" to "android",
            "p2pDeviceAddress" to "",
            "p2pSsid" to ssid,
            "p2pPassphrase" to pass,
            "p2pGoIp" to DEFAULT_GO_IP,
            "airToken" to ""
        )
    }

    private fun decodeFormat02(adv: ByteArray, resp: ByteArray?): Map<String, Any>? {
        if (adv.size < 6) return null
        if (resp == null || resp.size < 8 || resp[0] != FORMAT_GENERIC_HOTSPOT) return null

        val port = ((adv[1].toInt() and 0xFF) shl 8) or (adv[2].toInt() and 0xFF)
        if (port <= 0) return null
        val o3 = adv[3].toInt() and 0xFF
        val o4 = adv[4].toInt() and 0xFF
        val ssidLen = adv[5].toInt() and 0xFF
        if (ssidLen <= 0 || ssidLen > 18 || adv.size < 6 + ssidLen) return null
        val ssid = String(adv, 6, ssidLen, Charsets.UTF_8)

        val hex12 = bytesToHex(resp, 1, 6)
        val passLen = resp[7].toInt() and 0xFF
        if (passLen <= 0 || passLen > 19 || resp.size < 8 + passLen) return null
        val pass = String(resp, 8, passLen, Charsets.UTF_8)

        if (ssid.isEmpty() || pass.isEmpty()) return null

        return mapOf(
            "id" to "ble-$hex12",
            "name" to "SendSnap Device",
            "port" to port,
            "deviceType" to "android",
            "p2pDeviceAddress" to "",
            "p2pSsid" to ssid,
            "p2pPassphrase" to pass,
            "p2pGoIp" to "192.168.$o3.$o4",
            "airToken" to ""
        )
    }

    private fun parseDeviceId6Bytes(deviceId: String): ByteArray {
        val hex = deviceId.replace("-", "").lowercase().filter { it in '0'..'9' || it in 'a'..'f' }.take(12)
        val padded = hex.padEnd(12, '0')
        val out = ByteArray(6)
        for (i in 0 until 6) {
            val hi = Character.digit(padded[i * 2], 16)
            val lo = Character.digit(padded[i * 2 + 1], 16)
            out[i] = (((if (hi >= 0) hi else 0) shl 4) or (if (lo >= 0) lo else 0)).toByte()
        }
        return out
    }

    private fun bytesToHex(data: ByteArray, offset: Int, len: Int): String {
        val chars = CharArray(len * 2)
        for (i in 0 until len) {
            val v = data[offset + i].toInt() and 0xFF
            chars[i * 2] = HEX_CHARS[v ushr 4]
            chars[i * 2 + 1] = HEX_CHARS[v and 0x0F]
        }
        return String(chars)
    }

    private fun parseIpLastTwoOctets(ip: String): Pair<Int, Int> {
        val parts = ip.split(".")
        if (parts.size == 4) {
            val o3 = parts[2].toIntOrNull()?.coerceIn(0, 255)
            val o4 = parts[3].toIntOrNull()?.coerceIn(0, 255)
            if (o3 != null && o4 != null) return o3 to o4
        }
        return 43 to 1
    }

    private fun truncateUtf8(input: String, maxBytes: Int): ByteArray {
        val raw = input.toByteArray(Charsets.UTF_8)
        if (raw.size <= maxBytes) return raw
        var end = maxBytes
        while (end > 0 && (raw[end].toInt() and 0xC0) == 0x80) {
            end--
        }
        return raw.copyOf(end)
    }

    fun dispose() {
        stopAdvertising()
        stopScanning()
        if (receiverRegistered) {
            try {
                context.applicationContext.unregisterReceiver(btStateReceiver)
            } catch (_: Exception) {}
            receiverRegistered = false
        }
        onPeerFound = null
    }
}
