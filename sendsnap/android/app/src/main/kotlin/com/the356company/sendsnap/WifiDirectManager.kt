package com.the356company.sendsnap

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import kotlin.random.Random

/**
 * Native Android Wi-Fi Direct (WifiP2pManager + DNS-SD) and LocalOnlyHotspot manager.
 * Enables zero-config automatic cross-Wi-Fi discovery and programmatic P2P pairing
 * without requiring both phones to share a Wi-Fi router.
 */
class WifiDirectManager(private val context: Context) {

    companion object {
        private const val TAG = "SendSnapWifiDirect"
        private const val SERVICE_INSTANCE = "SendSnap"
        private const val SERVICE_TYPE = "_sendsnap._tcp"
        private const val DEFAULT_GO_IP = "192.168.49.1"
        private const val DEFAULT_LOHS_IP = "192.168.43.1"
        private val DIRECT_SSID_REGEX = Regex("^DIRECT-[a-zA-Z0-9][a-zA-Z0-9].*")
        private const val ALPHANUM = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnopqrstuvwxyz"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val wifiManager: WifiManager? =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val connectivityManager: ConnectivityManager? =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val p2pManager: WifiP2pManager? =
        context.applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var p2pChannel: WifiP2pManager.Channel? = null

    private var receiverRegistered = false
    private var isAdvertising = false
    private var isDiscovering = false
    private var wantsDiscovery = false
    private var isPassiveDiscovery = false
    private var isConnecting = false
    private var isDiscoveryCallInFlight = false
    private var consecutiveBusyCount = 0
    private var lastNotifiedWifiState: Boolean? = null
    private var dnsSdListenersRegistered = false
    private var advertisingGen = 0
    private val bleDiscovery = BleDiscoveryManager(context)
    private var activeDeviceId: String = ""
    private var activeDeviceName: String = "SendSnap Device"

    // Active Receiver Group / Hotspot credentials
    private var activeSsid: String? = null
    private var activePassphrase: String? = null
    private var activeGoIp: String? = null
    private var activePort: Int = 53318
    private var activeAirToken: String? = null
    private var activeHotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null

    // Active Sender Connection state
    private var connectedSsid: String? = null
    private var connectedGoIp: String? = null
    private var activeNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var boundNetwork: Network? = null

    // Callbacks to Flutter
    var onPeerFound: ((Map<String, Any>) -> Unit)? = null
    var onHotspotReady: ((Map<String, Any>) -> Unit)? = null
    var onConnectionChanged: ((Boolean, String?) -> Unit)? = null
    var onWifiStateChanged: ((Boolean) -> Unit)? = null

    // Pending connect awaiters
    private var pendingP2pConnectHandler: ((WifiP2pInfo) -> Unit)? = null

    private val p2pReceiver = object : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            when (action) {
                WifiManager.WIFI_STATE_CHANGED_ACTION -> {
                    val wifiState = intent.getIntExtra(
                        WifiManager.EXTRA_WIFI_STATE,
                        WifiManager.WIFI_STATE_UNKNOWN
                    )
                    if (wifiState == WifiManager.WIFI_STATE_DISABLED ||
                        wifiState == WifiManager.WIFI_STATE_DISABLING
                    ) {
                        mainHandler.removeCallbacks(discoveryRefreshRunnable)
                        mainHandler.removeCallbacks(busyRetryRunnable)
                        mainHandler.removeCallbacks(reAddServiceRequestRunnable)
                        isDiscoveryCallInFlight = false
                        isDiscovering = false
                        consecutiveBusyCount = 0
                        if (lastNotifiedWifiState != false) {
                            lastNotifiedWifiState = false
                            mainHandler.post { onWifiStateChanged?.invoke(false) }
                        }
                    } else if (wifiState == WifiManager.WIFI_STATE_ENABLED) {
                        consecutiveBusyCount = 0
                        if (lastNotifiedWifiState != true) {
                            lastNotifiedWifiState = true
                            mainHandler.post { onWifiStateChanged?.invoke(true) }
                        }
                        if (isAdvertising && activeSsid == null && activeDeviceId.isNotEmpty()) {
                            mainHandler.postDelayed({
                                if (isAdvertising && activeSsid == null && activeDeviceId.isNotEmpty() && isWifiEnabled()) {
                                    startAdvertising(activeDeviceId, activeDeviceName, activePort, activeAirToken) { _, _ -> }
                                }
                            }, 400L)
                        } else if (wantsDiscovery && !isAdvertising && !isConnecting) {
                            mainHandler.postDelayed({
                                if (wantsDiscovery && !isAdvertising && !isConnecting && isWifiEnabled()) {
                                    startDiscovery(isPassiveDiscovery)
                                }
                            }, 400L)
                        }
                    }
                }
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(
                        WifiP2pManager.EXTRA_WIFI_STATE,
                        WifiP2pManager.WIFI_P2P_STATE_DISABLED
                    )
                    Log.d(TAG, "P2P state changed: $state")
                    if (state == WifiP2pManager.WIFI_P2P_STATE_DISABLED) {
                        mainHandler.removeCallbacks(discoveryRefreshRunnable)
                        mainHandler.removeCallbacks(busyRetryRunnable)
                        mainHandler.removeCallbacks(reAddServiceRequestRunnable)
                        isDiscoveryCallInFlight = false
                        isDiscovering = false
                        consecutiveBusyCount = 0
                    } else if (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                        if (wantsDiscovery && !isAdvertising && !isConnecting && !isDiscovering && isWifiEnabled()) {
                            mainHandler.postDelayed({
                                if (wantsDiscovery && !isAdvertising && !isConnecting && !isDiscovering && isWifiEnabled()) {
                                    startDiscovery(isPassiveDiscovery)
                                }
                            }, 300L)
                        }
                    }
                }
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val channel = p2pChannel ?: return
                    val manager = p2pManager ?: return
                    if (!hasP2pPermission()) return
                    try {
                        manager.requestConnectionInfo(channel) { info ->
                            if (info != null && info.groupFormed) {
                                val goIp = info.groupOwnerAddress?.hostAddress
                                Log.d(TAG, "P2P group formed (isGO=${info.isGroupOwner}, goIp=$goIp)")
                                pendingP2pConnectHandler?.invoke(info)
                                if (isAdvertising && info.isGroupOwner && !goIp.isNullOrEmpty()) {
                                    activeGoIp = goIp
                                }
                            } else if (info != null && !info.groupFormed && connectedSsid != null && boundNetwork == null) {
                                connectedSsid = null
                                connectedGoIp = null
                                mainHandler.post {
                                    onConnectionChanged?.invoke(false, null)
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "requestConnectionInfo note: ${e.message}")
                    }
                }
            }
        }
    }

    private val busyRetryRunnable = Runnable {
        if (!isDiscovering || isConnecting || !isWifiEnabled() || !hasP2pPermission()) return@Runnable
        triggerServiceDiscovery()
    }

    private val reAddServiceRequestRunnable = Runnable {
        if (!isDiscovering || isConnecting || !isWifiEnabled() || !hasP2pPermission()) return@Runnable
        val manager = p2pManager ?: return@Runnable
        val channel = p2pChannel ?: return@Runnable
        addServiceRequestAndRun(manager, channel)
    }

    private val discoveryRefreshRunnable = object : Runnable {
        override fun run() {
            if (!isDiscovering || isConnecting || !isWifiEnabled()) return
            triggerServiceDiscovery()
            val delay = if (isPassiveDiscovery) 20_000L else 10_000L
            mainHandler.postDelayed(this, delay)
        }
    }

    private val advertiseKeepAliveRunnable = object : Runnable {
        override fun run() {
            if (!isAdvertising || isConnecting) return
            ensureListenOrPeerDiscover()
            mainHandler.postDelayed(this, 15_000L)
        }
    }

    init {
        lastNotifiedWifiState = isWifiEnabled()
        p2pChannel = try {
            p2pManager?.initialize(context.applicationContext, Looper.getMainLooper()) {
                Log.w(TAG, "WifiP2pManager channel disconnected")
            }
        } catch (e: Exception) {
            Log.e(TAG, "WifiP2pManager init failed: ${e.message}")
            null
        }
        registerP2pReceiver()
        bleDiscovery.onPeerFound = { peerMap ->
            mainHandler.post {
                onPeerFound?.invoke(peerMap)
            }
        }
    }

    private fun registerP2pReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        try {
            ContextCompat.registerReceiver(
                context.applicationContext,
                p2pReceiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            receiverRegistered = true
        } catch (e: Exception) {
            Log.e(TAG, "registerP2pReceiver failed: ${e.message}")
        }
    }

    fun hasP2pPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.NEARBY_WIFI_DEVICES
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    @Suppress("DEPRECATION")
    fun isLocationReady(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lm?.isLocationEnabled ?: true
            } else {
                Settings.Secure.getInt(
                    context.contentResolver,
                    Settings.Secure.LOCATION_MODE,
                    Settings.Secure.LOCATION_MODE_OFF
                ) != Settings.Secure.LOCATION_MODE_OFF
            }
        } catch (_: Exception) {
            true
        }
    }

    fun isWifiEnabled(): Boolean {
        return try {
            wifiManager?.isWifiEnabled == true
        } catch (_: Exception) {
            false
        }
    }

    fun getStatus(): Map<String, Any> {
        return mapOf(
            "supported" to (p2pManager != null && p2pChannel != null),
            "wifiEnabled" to isWifiEnabled(),
            "hasPermission" to hasP2pPermission(),
            "locationEnabled" to isLocationReady(),
            "bluetoothEnabled" to bleDiscovery.isBluetoothEnabled(),
            "hasBlePermission" to (bleDiscovery.hasScanPermission() && bleDiscovery.hasAdvertisePermission()),
            "isGroupActive" to (activeSsid != null && activePassphrase != null),
            "ssid" to (activeSsid ?: ""),
            "passphrase" to (activePassphrase ?: ""),
            "goIp" to (activeGoIp ?: "")
        )
    }

    @Suppress("DEPRECATION")
    fun openWifiPanel(activity: Activity?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return try {
                wifiManager?.setWifiEnabled(true) ?: false
            } catch (e: Exception) {
                Log.w(TAG, "Legacy setWifiEnabled failed: ${e.message}")
                false
            }
        }
        if (activity == null) return false
        return try {
            val panelIntent = Intent(Settings.Panel.ACTION_WIFI)
            if (panelIntent.resolveActivity(activity.packageManager) != null) {
                activity.startActivity(panelIntent)
                return true
            }
            val fallback = Intent(Settings.ACTION_WIFI_SETTINGS)
            activity.startActivity(fallback)
            true
        } catch (e: Exception) {
            Log.e(TAG, "openWifiPanel error: ${e.message}")
            false
        }
    }

    fun openHotspotSettings(activity: Activity?): Boolean {
        if (activity == null) return false
        val candidates = listOf(
            Intent().setClassName("com.android.settings", "com.android.settings.TetherSettings"),
            Intent("android.settings.TETHER_SETTINGS"),
            Intent(Settings.ACTION_WIRELESS_SETTINGS),
            Intent(Settings.ACTION_WIFI_SETTINGS)
        )
        for (intent in candidates) {
            try {
                if (intent.resolveActivity(activity.packageManager) != null) {
                    activity.startActivity(intent)
                    return true
                }
            } catch (e: Exception) {
                Log.w(TAG, "openHotspotSettings candidate failed (${intent.action ?: intent.component}): ${e.message}")
            }
        }
        return false
    }

    // -------------------------------------------------------------------------
    // Receiver Advertising (Autonomous Group Owner + DNS-SD + LOHS Fallback)
    // -------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun startAdvertising(
        deviceId: String,
        deviceName: String,
        port: Int,
        airToken: String? = null,
        onResult: (Boolean, String?) -> Unit
    ) {
        if (!hasP2pPermission()) {
            onResult(false, "Nearby Wi-Fi permission not granted")
            return
        }

        activeDeviceId = deviceId
        activeDeviceName = deviceName
        activeAirToken = airToken?.takeIf { it.isNotBlank() }

        // Android 8+ LocalOnlyHotspot works directly even when the master Wi-Fi toggle is OFF
        if (!isWifiEnabled()) {
            stopDiscoveryInternal()
            mainHandler.removeCallbacks(advertiseKeepAliveRunnable)
            closeHotspotReservation()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val gen = ++advertisingGen
                isAdvertising = true
                activePort = port
                activeSsid = null
                activePassphrase = null
                activeGoIp = null
                startLocalOnlyHotspotFallback(port, gen, onResult)
            } else {
                @Suppress("DEPRECATION")
                wifiManager?.setWifiEnabled(true)
                mainHandler.postDelayed({
                    if (isWifiEnabled()) {
                        startAdvertising(deviceId, deviceName, port, airToken, onResult)
                    } else {
                        onResult(false, "Could not enable Wi-Fi")
                    }
                }, 700L)
            }
            return
        }

        val manager = p2pManager
        val channel = p2pChannel
        if (manager == null || channel == null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                advertisingGen++
                startLocalOnlyHotspotFallback(port, advertisingGen, onResult)
            } else {
                onResult(false, "Wi-Fi Direct not supported")
            }
            return
        }

        stopDiscoveryInternal()
        mainHandler.removeCallbacks(advertiseKeepAliveRunnable)
        closeHotspotReservation()

        val gen = ++advertisingGen
        isAdvertising = true
        activePort = port
        activeSsid = null
        activePassphrase = null
        activeGoIp = null

        val customSsid = "DIRECT-S5-Snap${randomAlphanum(4)}"
        val customPass = randomAlphanum(8)

        manager.clearLocalServices(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                removeOldGroupAndCreate(manager, channel, gen, deviceId, deviceName, port, customSsid, customPass, onResult)
            }

            override fun onFailure(reason: Int) {
                removeOldGroupAndCreate(manager, channel, gen, deviceId, deviceName, port, customSsid, customPass, onResult)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun removeOldGroupAndCreate(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        gen: Int,
        deviceId: String,
        deviceName: String,
        port: Int,
        customSsid: String,
        customPass: String,
        onResult: (Boolean, String?) -> Unit
    ) {
        if (gen != advertisingGen || !isAdvertising) return
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                mainHandler.postDelayed({
                    createGroupWithRetry(manager, channel, gen, deviceId, deviceName, port, customSsid, customPass, 0, onResult)
                }, 180L)
            }

            override fun onFailure(reason: Int) {
                createGroupWithRetry(manager, channel, gen, deviceId, deviceName, port, customSsid, customPass, 0, onResult)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun createGroupWithRetry(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        gen: Int,
        deviceId: String,
        deviceName: String,
        port: Int,
        customSsid: String,
        customPass: String,
        attempt: Int,
        onResult: (Boolean, String?) -> Unit
    ) {
        if (gen != advertisingGen || !isAdvertising) return

        val listener = object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                if (gen != advertisingGen || !isAdvertising) return
                Log.d(TAG, "createGroup succeeded (attempt $attempt)")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    activeSsid = customSsid
                    activePassphrase = customPass
                    activeGoIp = DEFAULT_GO_IP
                }
                pollGroupInfoAndRegisterService(manager, channel, gen, deviceId, deviceName, port, 0, onResult)
            }

            override fun onFailure(reason: Int) {
                if (gen != advertisingGen || !isAdvertising) return
                Log.w(TAG, "createGroup failed reason=$reason attempt=$attempt")
                if (reason == WifiP2pManager.BUSY && attempt == 0) {
                    mainHandler.postDelayed({
                        createGroupWithRetry(manager, channel, gen, deviceId, deviceName, port, customSsid, customPass, 1, onResult)
                    }, 600L)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startLocalOnlyHotspotFallback(port, gen, onResult)
                } else {
                    isAdvertising = false
                    onResult(false, "Wi-Fi Direct group error ($reason)")
                }
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val config = WifiP2pConfig.Builder()
                    .setNetworkName(customSsid)
                    .setPassphrase(customPass)
                    .enablePersistentMode(false)
                    .build()
                manager.createGroup(channel, config, listener)
            } else {
                manager.createGroup(channel, listener)
            }
        } catch (e: Exception) {
            Log.e(TAG, "createGroup exception: ${e.message}")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startLocalOnlyHotspotFallback(port, gen, onResult)
            } else {
                isAdvertising = false
                onResult(false, e.message)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun pollGroupInfoAndRegisterService(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        gen: Int,
        deviceId: String,
        deviceName: String,
        port: Int,
        retry: Int,
        onResult: (Boolean, String?) -> Unit
    ) {
        if (gen != advertisingGen || !isAdvertising) return
        mainHandler.postDelayed({
            if (gen != advertisingGen || !isAdvertising) return@postDelayed
            manager.requestGroupInfo(channel) { group: WifiP2pGroup? ->
                if (gen != advertisingGen || !isAdvertising) return@requestGroupInfo
                if (group != null) {
                    if (!group.networkName.isNullOrEmpty()) {
                        activeSsid = group.networkName
                    }
                    if (!group.passphrase.isNullOrEmpty()) {
                        activePassphrase = group.passphrase
                    }
                    manager.requestConnectionInfo(channel) { info ->
                        val goIp = info?.groupOwnerAddress?.hostAddress ?: DEFAULT_GO_IP
                        activeGoIp = goIp
                        finishAdvertisingSetup(manager, channel, gen, deviceId, deviceName, port, onResult)
                    }
                } else if (retry < 3) {
                    pollGroupInfoAndRegisterService(manager, channel, gen, deviceId, deviceName, port, retry + 1, onResult)
                } else {
                    // On API 29+ we already have the requested custom credentials even if group info lags
                    if (!activeSsid.isNullOrEmpty() && !activePassphrase.isNullOrEmpty()) {
                        activeGoIp = activeGoIp ?: DEFAULT_GO_IP
                        finishAdvertisingSetup(manager, channel, gen, deviceId, deviceName, port, onResult)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startLocalOnlyHotspotFallback(port, gen, onResult)
                    } else {
                        isAdvertising = false
                        onResult(false, "Group info unavailable")
                    }
                }
            }
        }, 250L)
    }

    @SuppressLint("MissingPermission")
    private fun finishAdvertisingSetup(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        gen: Int,
        deviceId: String,
        deviceName: String,
        port: Int,
        onResult: (Boolean, String?) -> Unit
    ) {
        if (gen != advertisingGen || !isAdvertising) return
        val ssid = activeSsid ?: ""
        val pass = activePassphrase ?: ""
        val goIp = activeGoIp ?: DEFAULT_GO_IP

        val hotspotMap = mapOf<String, Any>(
            "ssid" to ssid,
            "passphrase" to pass,
            "goIp" to goIp,
            "port" to port
        )
        mainHandler.post {
            onHotspotReady?.invoke(hotspotMap)
        }
        bleDiscovery.startAdvertising(deviceId, deviceName, port, ssid, pass, goIp)

        // Register compact DNS-SD TXT service so nearby senders discover SSID/pass automatically
        val txtRecord = mutableMapOf(
            "id" to deviceId,
            "n" to deviceName.take(32),
            "p" to port.toString(),
            "t" to "android",
            "s" to ssid,
            "k" to pass,
            "g" to goIp
        )
        activeAirToken?.takeIf { it.isNotEmpty() }?.let { token ->
            txtRecord["air"] = token
        }
        val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(
            SERVICE_INSTANCE,
            SERVICE_TYPE,
            txtRecord
        )

        manager.addLocalService(channel, serviceInfo, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                if (gen != advertisingGen || !isAdvertising) return
                Log.d(TAG, "Local DNS-SD service registered ($ssid)")
                ensureListenOrPeerDiscover()
                mainHandler.removeCallbacks(advertiseKeepAliveRunnable)
                mainHandler.postDelayed(advertiseKeepAliveRunnable, 15_000L)
                onResult(true, null)
            }

            override fun onFailure(reason: Int) {
                Log.w(TAG, "addLocalService failed reason=$reason (QR hotspot still ready)")
                // Even if DNS-SD registration fails on an OEM ROM, QR Auto-Join hotspot works
                onResult(true, null)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun ensureListenOrPeerDiscover() {
        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        if (!hasP2pPermission() || !isAdvertising) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.startListening(channel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {}
                    override fun onFailure(reason: Int) {
                        Log.w(TAG, "startListening note: $reason")
                    }
                })
            } else {
                manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {}
                    override fun onFailure(reason: Int) {
                        Log.w(TAG, "discoverPeers keepalive note: $reason")
                    }
                })
            }
        } catch (e: Exception) {
            Log.w(TAG, "ensureListenOrPeerDiscover note: ${e.message}")
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun startLocalOnlyHotspotFallback(
        port: Int,
        gen: Int,
        onResult: (Boolean, String?) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            isAdvertising = false
            onResult(false, "Hotspot fallback requires Android 8+")
            return
        }
        val wm = wifiManager
        if (wm == null) {
            isAdvertising = false
            onResult(false, "WifiManager unavailable")
            return
        }

        closeHotspotReservation()
        try {
            wm.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation?) {
                    if (gen != advertisingGen || !isAdvertising) {
                        reservation?.close()
                        return
                    }
                    activeHotspotReservation = reservation
                    var ssid = ""
                    var pass = ""
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val cfg = reservation?.softApConfiguration
                        ssid = cfg?.ssid ?: ""
                        pass = cfg?.passphrase ?: ""
                    } else {
                        val cfg = reservation?.wifiConfiguration
                        ssid = cfg?.SSID?.removeSurrounding("\"") ?: ""
                        pass = cfg?.preSharedKey?.removeSurrounding("\"") ?: ""
                    }

                    mainHandler.postDelayed({
                        val goIp = findSoftApIpAddress() ?: DEFAULT_LOHS_IP
                        activeSsid = ssid
                        activePassphrase = pass
                        activeGoIp = goIp
                        val hotspotMap = mapOf<String, Any>(
                            "ssid" to ssid,
                            "passphrase" to pass,
                            "goIp" to goIp,
                            "port" to port
                        )
                        onHotspotReady?.invoke(hotspotMap)
                        bleDiscovery.startAdvertising(
                            activeDeviceId,
                            activeDeviceName,
                            port,
                            ssid,
                            pass,
                            goIp
                        )
                        onResult(true, null)
                    }, 300L)
                }

                override fun onStopped() {
                    activeHotspotReservation = null
                }

                override fun onFailed(reason: Int) {
                    Log.e(TAG, "LocalOnlyHotspot failed reason=$reason")
                    isAdvertising = false
                    onResult(false, "Direct hotspot unavailable (code $reason)")
                }
            }, mainHandler)
        } catch (e: Exception) {
            Log.e(TAG, "startLocalOnlyHotspot exception: ${e.message}")
            isAdvertising = false
            onResult(false, e.message)
        }
    }

    private fun findSoftApIpAddress(): String? {
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return null
            for (iface in ifaces) {
                val name = iface.name.lowercase()
                if (name.contains("ap") || name.contains("swlan") || name.contains("softap")) {
                    for (addr in iface.inetAddresses) {
                        if (addr is Inet4Address && !addr.isLoopbackAddress) {
                            return addr.hostAddress
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return null
    }

    @SuppressLint("MissingPermission")
    fun stopAdvertising() {
        advertisingGen++
        isAdvertising = false
        bleDiscovery.stopAdvertising()
        mainHandler.removeCallbacks(advertiseKeepAliveRunnable)
        activeSsid = null
        activePassphrase = null
        activeGoIp = null
        activeAirToken = null
        closeHotspotReservation()
        mainHandler.post {
            onHotspotReady?.invoke(emptyMap())
        }

        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.stopListening(channel, null)
            } else {
                manager.stopPeerDiscovery(channel, null)
            }
            manager.clearLocalServices(channel, null)
            manager.removeGroup(channel, null)
        } catch (e: Exception) {
            Log.w(TAG, "stopAdvertising cleanup note: ${e.message}")
        }
    }

    private fun closeHotspotReservation() {
        try {
            activeHotspotReservation?.close()
        } catch (_: Exception) {}
        activeHotspotReservation = null
    }

    // -------------------------------------------------------------------------
    // Sender Discovery (DNS-SD over Wi-Fi P2P)
    // -------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun startDiscovery(isPassive: Boolean): Boolean {
        wantsDiscovery = true
        isPassiveDiscovery = isPassive
        if (isAdvertising) return false
        if (connectedSsid != null) return true

        bleDiscovery.startScanning(isPassive)

        if (!isWifiEnabled() || !hasP2pPermission() || !isLocationReady()) {
            return false
        }
        val manager = p2pManager ?: return false
        val channel = p2pChannel ?: return false

        if (isDiscovering) {
            setDiscoveryPace(isPassive)
            return true
        }

        ensureDnsSdListeners(manager, channel)
        isDiscovering = true
        consecutiveBusyCount = 0

        manager.clearServiceRequests(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                if (!isDiscovering) return
                addServiceRequestAndRun(manager, channel)
            }

            override fun onFailure(reason: Int) {
                if (!isDiscovering) return
                addServiceRequestAndRun(manager, channel)
            }
        })
        return true
    }

    @SuppressLint("MissingPermission")
    private fun addServiceRequestAndRun(manager: WifiP2pManager, channel: WifiP2pManager.Channel) {
        val request = WifiP2pDnsSdServiceRequest.newInstance()
        manager.addServiceRequest(channel, request, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                if (!isDiscovering) return
                mainHandler.removeCallbacks(discoveryRefreshRunnable)
                mainHandler.post(discoveryRefreshRunnable)
            }

            override fun onFailure(reason: Int) {
                Log.w(TAG, "addServiceRequest failed: $reason")
                isDiscovering = false
            }
        })
    }

    private fun ensureDnsSdListeners(manager: WifiP2pManager, channel: WifiP2pManager.Channel) {
        if (dnsSdListenersRegistered) return
        dnsSdListenersRegistered = true

        manager.setDnsSdResponseListeners(
            channel,
            { _, _, _ -> /* TXT record listener carries full device payload */ },
            { fullDomainName, record, srcDevice ->
                val domain = fullDomainName.lowercase()
                if (!domain.contains("_sendsnap._tcp") && !(record.containsKey("id") && record.containsKey("n"))) {
                    return@setDnsSdResponseListeners
                }
                val id = record["id"] ?: return@setDnsSdResponseListeners
                val name = record["n"] ?: srcDevice.deviceName ?: "SendSnap Device"
                val port = record["p"]?.toIntOrNull() ?: 53318
                val deviceType = record["t"] ?: "android"
                val ssid = record["s"] ?: ""
                val passphrase = record["k"] ?: ""
                val goIp = record["g"] ?: DEFAULT_GO_IP
                val airToken = record["air"] ?: ""

                val peerMap = mapOf<String, Any>(
                    "id" to id,
                    "name" to name,
                    "port" to port,
                    "deviceType" to deviceType,
                    "p2pDeviceAddress" to (srcDevice.deviceAddress ?: ""),
                    "p2pSsid" to ssid,
                    "p2pPassphrase" to passphrase,
                    "p2pGoIp" to goIp,
                    "airToken" to airToken
                )
                mainHandler.post {
                    onPeerFound?.invoke(peerMap)
                }
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun triggerServiceDiscovery() {
        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        if (!isDiscovering || isConnecting || isDiscoveryCallInFlight || !isWifiEnabled() || !hasP2pPermission()) {
            return
        }

        isDiscoveryCallInFlight = true
        manager.discoverServices(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                isDiscoveryCallInFlight = false
                consecutiveBusyCount = 0
                Log.d(TAG, "P2P discoverServices started")
            }

            override fun onFailure(reason: Int) {
                isDiscoveryCallInFlight = false
                Log.w(TAG, "P2P discoverServices failed reason=$reason")
                if (reason == WifiP2pManager.BUSY && isDiscovering && !isConnecting && isWifiEnabled()) {
                    consecutiveBusyCount++
                    mainHandler.removeCallbacks(busyRetryRunnable)
                    if (consecutiveBusyCount <= 3) {
                        if (consecutiveBusyCount >= 2) {
                            try {
                                manager.stopPeerDiscovery(channel, null)
                            } catch (_: Exception) {}
                        }
                        mainHandler.postDelayed(busyRetryRunnable, 2000L * consecutiveBusyCount)
                    }
                } else if (reason == WifiP2pManager.NO_SERVICE_REQUESTS && isDiscovering && !isConnecting && isWifiEnabled()) {
                    mainHandler.removeCallbacks(reAddServiceRequestRunnable)
                    mainHandler.postDelayed(reAddServiceRequestRunnable, 800L)
                }
            }
        })
    }

    fun setDiscoveryPace(isPassive: Boolean) {
        val wasPassive = isPassiveDiscovery
        isPassiveDiscovery = isPassive
        bleDiscovery.setScanPace(isPassive)
        if (isDiscovering && wasPassive && !isPassive && !isConnecting && isWifiEnabled()) {
            mainHandler.removeCallbacks(discoveryRefreshRunnable)
            mainHandler.removeCallbacks(busyRetryRunnable)
            mainHandler.post(discoveryRefreshRunnable)
        }
    }

    fun stopDiscovery() {
        stopDiscoveryInternal()
    }

    @SuppressLint("MissingPermission")
    private fun stopDiscoveryInternal() {
        wantsDiscovery = false
        isDiscovering = false
        isDiscoveryCallInFlight = false
        consecutiveBusyCount = 0
        bleDiscovery.stopScanning()
        mainHandler.removeCallbacks(discoveryRefreshRunnable)
        mainHandler.removeCallbacks(busyRetryRunnable)
        mainHandler.removeCallbacks(reAddServiceRequestRunnable)
        val manager = p2pManager ?: return
        val channel = p2pChannel ?: return
        try {
            manager.clearServiceRequests(channel, null)
            manager.stopPeerDiscovery(channel, null)
        } catch (e: Exception) {
            Log.w(TAG, "stopDiscovery note: ${e.message}")
        }
    }

    // -------------------------------------------------------------------------
    // Zero-Config Direct Connect (P2P Config -> WifiNetworkSpecifier -> PBC)
    // -------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun connectToPeer(
        ssid: String?,
        passphrase: String?,
        deviceAddress: String?,
        goIp: String?,
        port: Int = 53318,
        onResult: (Boolean, String?, String?) -> Unit
    ) {
        if (!isWifiEnabled()) {
            onResult(false, null, "Wi-Fi is turned off")
            return
        }

        // Fast reuse if already linked to this exact Direct Wi-Fi network and still routable
        if (!ssid.isNullOrEmpty() && ssid == connectedSsid && !connectedGoIp.isNullOrEmpty()) {
            val cachedIp = connectedGoIp!!
            verifyTcpReachable(cachedIp, port, attempts = 1, connectTimeoutMs = 600) { reachable ->
                if (reachable) {
                    onResult(true, cachedIp, null)
                } else {
                    Log.w(TAG, "Cached direct link $cachedIp:$port unreachable; reconnecting")
                    connectedSsid = null
                    connectedGoIp = null
                    unregisterSpecifierNetwork()
                    connectToPeer(ssid, passphrase, deviceAddress, goIp, port, onResult)
                }
            }
            return
        }

        isConnecting = true
        stopDiscoveryInternal()

        var finished = false
        fun complete(success: Boolean, ip: String?, error: String?) {
            if (finished) return
            finished = true
            isConnecting = false
            pendingP2pConnectHandler = null
            if (success) {
                connectedSsid = ssid
                connectedGoIp = ip
            }
            mainHandler.post {
                onConnectionChanged?.invoke(success, ip)
                onResult(success, ip, error)
            }
        }

        fun fallbackToSpecifier(
            targetSsid: String,
            targetPass: String,
            fallbackIp: String
        ) {
            val mgr = p2pManager
            val ch = p2pChannel
            if (mgr != null && ch != null) {
                try {
                    mgr.cancelConnect(ch, null)
                    mgr.removeGroup(ch, null)
                } catch (_: Exception) {}
            }
            mainHandler.postDelayed({
                if (finished) return@postDelayed
                connectViaWifiSpecifier(targetSsid, targetPass, fallbackIp) { specOk, specIp, specErr ->
                    complete(specOk, specIp, specErr)
                }
            }, 250L)
        }

        val hasValidDirectCreds = !ssid.isNullOrEmpty() &&
            !passphrase.isNullOrEmpty() &&
            DIRECT_SSID_REGEX.matches(ssid) &&
            passphrase.length in 8..63

        // Path 1: Zero-dialog programmatic P2P connect on Android 10+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            hasValidDirectCreds &&
            p2pManager != null &&
            p2pChannel != null &&
            hasP2pPermission()
        ) {
            connectViaP2pConfig(
                p2pManager,
                p2pChannel!!,
                ssid!!,
                passphrase!!,
                goIp ?: DEFAULT_GO_IP
            ) { ok, resolvedIp ->
                if (ok && !resolvedIp.isNullOrEmpty()) {
                    verifyTcpReachable(
                        resolvedIp,
                        port,
                        attempts = 3,
                        connectTimeoutMs = 900,
                        retryDelayMs = 350L
                    ) { reachable ->
                        if (reachable) {
                            complete(true, resolvedIp, null)
                        } else {
                            Log.w(
                                TAG,
                                "P2P L2 group formed ($resolvedIp:$port) but not routable; falling back to WifiNetworkSpecifier"
                            )
                            fallbackToSpecifier(ssid, passphrase, goIp ?: DEFAULT_GO_IP)
                        }
                    }
                } else {
                    // Path 2 fallback: WifiNetworkSpecifier (handles LOHS & OEM P2P quirks)
                    fallbackToSpecifier(ssid, passphrase, goIp ?: DEFAULT_GO_IP)
                }
            }
            return
        }

        // Path 2: WifiNetworkSpecifier (e.g., LocalOnlyHotspot fallback or non-DIRECT SSID)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            !ssid.isNullOrEmpty() &&
            !passphrase.isNullOrEmpty()
        ) {
            connectViaWifiSpecifier(ssid, passphrase, goIp ?: DEFAULT_LOHS_IP) { specOk, specIp, specErr ->
                complete(specOk, specIp, specErr)
            }
            return
        }

        // Path 3: Legacy Android 7-9 PBC fallback
        if (!deviceAddress.isNullOrEmpty() &&
            p2pManager != null &&
            p2pChannel != null &&
            hasP2pPermission()
        ) {
            connectViaLegacyPbc(p2pManager, p2pChannel!!, deviceAddress, goIp ?: DEFAULT_GO_IP) { ok, resolvedIp, err ->
                complete(ok, resolvedIp, err)
            }
            return
        }

        complete(false, null, "No Direct Wi-Fi credentials or peer address available")
    }

    @SuppressLint("MissingPermission")
    private fun connectViaP2pConfig(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        ssid: String,
        passphrase: String,
        fallbackIp: String,
        onDone: (Boolean, String?) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onDone(false, null)
            return
        }

        var done = false
        val timeoutRunnable = Runnable {
            if (done) return@Runnable
            done = true
            pendingP2pConnectHandler = null
            try {
                manager.cancelConnect(channel, null)
            } catch (_: Exception) {}
            Log.w(TAG, "P2P config connect timed out, falling back to WifiNetworkSpecifier")
            onDone(false, null)
        }

        pendingP2pConnectHandler = { info ->
            if (!done && info.groupFormed) {
                done = true
                mainHandler.removeCallbacks(timeoutRunnable)
                pendingP2pConnectHandler = null
                val ip = info.groupOwnerAddress?.hostAddress ?: fallbackIp
                onDone(true, ip)
            }
        }

        val config = WifiP2pConfig.Builder()
            .setNetworkName(ssid)
            .setPassphrase(passphrase)
            .enablePersistentMode(false)
            .build()

        mainHandler.postDelayed(timeoutRunnable, 6_000L)
        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "P2P config connect initiated for $ssid")
                // Poll connectionInfo periodically in case broadcast is delayed
                fun pollInfo(attempt: Int) {
                    if (done || attempt >= 10) return
                    mainHandler.postDelayed({
                        if (done) return@postDelayed
                        manager.requestConnectionInfo(channel) { info ->
                            if (!done && info != null && info.groupFormed) {
                                pendingP2pConnectHandler?.invoke(info)
                            } else {
                                pollInfo(attempt + 1)
                            }
                        }
                    }, 700L)
                }
                pollInfo(0)
            }

            override fun onFailure(reason: Int) {
                if (done) return
                done = true
                mainHandler.removeCallbacks(timeoutRunnable)
                pendingP2pConnectHandler = null
                Log.w(TAG, "P2P config connect failed reason=$reason")
                onDone(false, null)
            }
        })
    }

    private fun connectViaWifiSpecifier(
        ssid: String,
        passphrase: String,
        fallbackIp: String,
        onDone: (Boolean, String?, String?) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onDone(false, null, "WifiNetworkSpecifier requires Android 10+")
            return
        }
        val cm = connectivityManager
        if (cm == null) {
            onDone(false, null, "ConnectivityManager unavailable")
            return
        }

        unregisterSpecifierNetwork()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var done = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    if (done) return@post
                    done = true
                    boundNetwork = network
                    try {
                        cm.bindProcessToNetwork(network)
                    } catch (e: Exception) {
                        Log.w(TAG, "bindProcessToNetwork warning: ${e.message}")
                    }
                    val resolvedIp = resolveGatewayIp(cm, network) ?: fallbackIp
                    Log.d(TAG, "WifiNetworkSpecifier connected to $ssid -> gateway=$resolvedIp")
                    onDone(true, resolvedIp, null)
                }
            }

            override fun onUnavailable() {
                mainHandler.post {
                    if (done) return@post
                    done = true
                    unregisterSpecifierNetwork()
                    onDone(false, null, "Direct Wi-Fi connection declined or unavailable")
                }
            }

            override fun onLost(network: Network) {
                mainHandler.post {
                    if (boundNetwork == network) {
                        try {
                            cm.bindProcessToNetwork(null)
                        } catch (_: Exception) {}
                        boundNetwork = null
                        connectedSsid = null
                        connectedGoIp = null
                        onConnectionChanged?.invoke(false, null)
                    }
                }
            }
        }

        activeNetworkCallback = callback
        try {
            cm.requestNetwork(request, callback, 35_000)
        } catch (e: Exception) {
            activeNetworkCallback = null
            onDone(false, null, e.message)
        }
    }

    private fun verifyTcpReachable(
        ip: String,
        port: Int,
        attempts: Int = 3,
        connectTimeoutMs: Int = 900,
        retryDelayMs: Long = 350L,
        onResult: (Boolean) -> Unit
    ) {
        if (ip.isBlank() || port <= 0) {
            mainHandler.post { onResult(false) }
            return
        }
        Thread {
            var reachable = false
            for (attempt in 0 until attempts) {
                var socket: Socket? = null
                try {
                    socket = Socket()
                    socket.connect(InetSocketAddress(ip, port), connectTimeoutMs)
                    reachable = true
                    break
                } catch (_: Exception) {
                    // L2 interface not yet routable or server unreachable
                } finally {
                    try {
                        socket?.close()
                    } catch (_: Exception) {}
                }
                if (attempt < attempts - 1) {
                    try {
                        Thread.sleep(retryDelayMs)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            mainHandler.post { onResult(reachable) }
        }.start()
    }

    private fun resolveGatewayIp(cm: ConnectivityManager, network: Network): String? {
        try {
            val props = cm.getLinkProperties(network) ?: return null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val dhcp = props.dhcpServerAddress
                if (dhcp is Inet4Address && !dhcp.isAnyLocalAddress && !dhcp.isLoopbackAddress) {
                    return dhcp.hostAddress
                }
            }
            for (route in props.routes) {
                val gw = route.gateway
                if (gw is Inet4Address && !gw.isAnyLocalAddress && !gw.isLoopbackAddress) {
                    return gw.hostAddress
                }
            }
            for (dns in props.dnsServers) {
                if (dns is Inet4Address &&
                    !dns.isAnyLocalAddress &&
                    !dns.isLoopbackAddress &&
                    isPrivateRfc1918(dns)
                ) {
                    return dns.hostAddress
                }
            }
        } catch (_: Exception) {}
        return null
    }

    private fun isPrivateRfc1918(addr: Inet4Address): Boolean {
        val bytes = addr.address
        if (bytes.size != 4) return false
        val first = bytes[0].toInt() and 0xFF
        val second = bytes[1].toInt() and 0xFF
        return first == 10 ||
            (first == 172 && second in 16..31) ||
            (first == 192 && second == 168)
    }

    @SuppressLint("MissingPermission")
    private fun connectViaLegacyPbc(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        deviceAddress: String,
        fallbackIp: String,
        onDone: (Boolean, String?, String?) -> Unit
    ) {
        var done = false
        val timeoutRunnable = Runnable {
            if (done) return@Runnable
            done = true
            pendingP2pConnectHandler = null
            try {
                manager.cancelConnect(channel, null)
            } catch (_: Exception) {}
            onDone(false, null, "Direct Wi-Fi pairing timed out")
        }

        pendingP2pConnectHandler = { info ->
            if (!done && info.groupFormed) {
                done = true
                mainHandler.removeCallbacks(timeoutRunnable)
                pendingP2pConnectHandler = null
                onDone(true, info.groupOwnerAddress?.hostAddress ?: fallbackIp, null)
            }
        }

        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
        }

        mainHandler.postDelayed(timeoutRunnable, 15_000L)
        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Legacy PBC connect initiated")
            }

            override fun onFailure(reason: Int) {
                if (done) return
                done = true
                mainHandler.removeCallbacks(timeoutRunnable)
                pendingP2pConnectHandler = null
                onDone(false, null, "Direct Wi-Fi pairing failed ($reason)")
            }
        })
    }

    private fun unregisterSpecifierNetwork() {
        val cm = connectivityManager
        if (cm != null) {
            try {
                cm.bindProcessToNetwork(null)
            } catch (_: Exception) {}
            activeNetworkCallback?.let { cb ->
                try {
                    cm.unregisterNetworkCallback(cb)
                } catch (_: Exception) {}
            }
        }
        activeNetworkCallback = null
        boundNetwork = null
    }

    @SuppressLint("MissingPermission")
    fun disconnectDirect() {
        isConnecting = false
        pendingP2pConnectHandler = null
        connectedSsid = null
        connectedGoIp = null
        unregisterSpecifierNetwork()

        if (!isAdvertising && p2pManager != null && p2pChannel != null) {
            try {
                p2pManager.cancelConnect(p2pChannel!!, null)
                p2pManager.removeGroup(p2pChannel!!, null)
            } catch (_: Exception) {}
        }
    }

    fun dispose() {
        stopDiscovery()
        stopAdvertising()
        disconnectDirect()
        bleDiscovery.dispose()
        if (receiverRegistered) {
            try {
                context.applicationContext.unregisterReceiver(p2pReceiver)
            } catch (_: Exception) {}
            receiverRegistered = false
        }
        onPeerFound = null
        onHotspotReady = null
        onConnectionChanged = null
        onWifiStateChanged = null
    }

    private fun randomAlphanum(length: Int): String {
        val sb = StringBuilder(length)
        repeat(length) {
            sb.append(ALPHANUM[Random.nextInt(ALPHANUM.length)])
        }
        return sb.toString()
    }
}
