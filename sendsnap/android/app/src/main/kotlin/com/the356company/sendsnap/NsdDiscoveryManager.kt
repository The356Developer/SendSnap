package com.the356company.sendsnap

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import java.net.Inet4Address
import java.net.InetAddress
import java.nio.charset.StandardCharsets

/**
 * Native Android mDNS / DNS-SD (NsdManager) discovery & advertising helper.
 * Complements UDP broadcast/multicast for sub-second LAN device discovery.
 */
class NsdDiscoveryManager(private val context: Context) {

    companion object {
        private const val TAG = "SendSnapNsd"
        private const val SERVICE_TYPE = "_sendsnap._tcp."
        private const val SERVICE_PREFIX = "SendSnap-"
    }

    private val nsdManager: NsdManager? =
        context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    private var localServiceId: String = ""
    private var registeredServiceName: String? = null
    private var onFoundCallback: ((Map<String, Any>) -> Unit)? = null
    private var onLostCallback: ((String) -> Unit)? = null

    // Serialized resolve queue for API < 34 to avoid FAILURE_ALREADY_ACTIVE
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var isResolvingLegacy = false

    // Active API 34+ ServiceInfoCallbacks to clean up on stop/dispose
    private val activeInfoCallbacks = mutableListOf<Any>()

    fun registerService(id: String, name: String, port: Int, deviceType: String) {
        val manager = nsdManager ?: return
        unregisterService()

        localServiceId = id
        val serviceName = "$SERVICE_PREFIX$id"

        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = SERVICE_TYPE
            this.port = port
            try {
                setAttribute("id", id)
                setAttribute("name", name.take(40))
                setAttribute("deviceType", deviceType)
            } catch (e: Exception) {
                Log.w(TAG, "setAttribute warning: ${e.message}")
            }
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredServiceName = info.serviceName
                Log.d(TAG, "NSD registered: ${info.serviceName} on port $port")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed: $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.d(TAG, "NSD unregistered: ${info.serviceName}")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD unregistration failed: $errorCode")
            }
        }

        registrationListener = listener
        try {
            manager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(TAG, "registerService exception: ${e.message}")
            registrationListener = null
        }
    }

    fun unregisterService() {
        val manager = nsdManager ?: return
        val listener = registrationListener ?: return
        registrationListener = null
        registeredServiceName = null
        try {
            manager.unregisterService(listener)
        } catch (e: Exception) {
            Log.w(TAG, "unregisterService note: ${e.message}")
        }
    }

    fun startDiscovery(
        localId: String,
        onFound: (Map<String, Any>) -> Unit,
        onLost: (String) -> Unit
    ) {
        val manager = nsdManager ?: return
        stopDiscovery()

        localServiceId = localId
        onFoundCallback = onFound
        onLostCallback = onLost

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.d(TAG, "NSD discovery started for $regType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val type = serviceInfo.serviceType ?: ""
                val svcName = serviceInfo.serviceName ?: ""
                if (!type.contains("_sendsnap._tcp")) return
                if (svcName == "$SERVICE_PREFIX$localServiceId" ||
                    (registeredServiceName != null && svcName == registeredServiceName)
                ) {
                    return
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    resolveModern(manager, serviceInfo)
                } else {
                    enqueueLegacyResolve(manager, serviceInfo)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val svcName = serviceInfo.serviceName ?: return
                val id = svcName.removePrefix(SERVICE_PREFIX)
                if (id.isNotEmpty() && id != localServiceId) {
                    mainHandler.post {
                        onLostCallback?.invoke(id)
                    }
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "NSD discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "NSD startDiscoveryFailed: $errorCode")
                discoveryListener = null
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "NSD stopDiscoveryFailed: $errorCode")
            }
        }

        discoveryListener = listener
        try {
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(TAG, "discoverServices exception: ${e.message}")
            discoveryListener = null
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun resolveModern(manager: NsdManager, serviceInfo: NsdServiceInfo) {
        val executor = ContextCompat.getMainExecutor(context)
        val callback = object : NsdManager.ServiceInfoCallback {
            private var emitted = false

            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                activeInfoCallbacks.remove(this)
            }

            override fun onServiceUpdated(updatedInfo: NsdServiceInfo) {
                if (emitted) return
                val ip = pickIpv4Address(updatedInfo.hostAddresses) ?: return
                emitted = true
                emitResolved(updatedInfo, ip)
                activeInfoCallbacks.remove(this)
                try {
                    manager.unregisterServiceInfoCallback(this)
                } catch (_: Exception) {}
            }

            override fun onServiceLost() {
                activeInfoCallbacks.remove(this)
                try {
                    manager.unregisterServiceInfoCallback(this)
                } catch (_: Exception) {}
            }

            override fun onServiceInfoCallbackUnregistered() {
                activeInfoCallbacks.remove(this)
            }
        }

        activeInfoCallbacks.add(callback)
        try {
            manager.registerServiceInfoCallback(serviceInfo, executor, callback)
            // Timeout guard so callbacks never linger if peer disappears mid-resolve
            mainHandler.postDelayed({
                if (activeInfoCallbacks.remove(callback)) {
                    try {
                        manager.unregisterServiceInfoCallback(callback)
                    } catch (_: Exception) {}
                }
            }, 4000L)
        } catch (e: Exception) {
            activeInfoCallbacks.remove(callback)
            Log.w(TAG, "registerServiceInfoCallback failed: ${e.message}")
        }
    }

    private fun enqueueLegacyResolve(manager: NsdManager, serviceInfo: NsdServiceInfo) {
        synchronized(resolveQueue) {
            resolveQueue.addLast(serviceInfo)
            if (!isResolvingLegacy) {
                isResolvingLegacy = true
                processNextLegacyResolve(manager)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun processNextLegacyResolve(manager: NsdManager) {
        val next: NsdServiceInfo? = synchronized(resolveQueue) {
            if (resolveQueue.isEmpty() || discoveryListener == null) {
                isResolvingLegacy = false
                null
            } else {
                resolveQueue.removeFirst()
            }
        }
        if (next == null) return

        try {
            manager.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    processNextLegacyResolve(manager)
                }

                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    val host = resolved.host
                    val ip = if (host is Inet4Address && !host.isLoopbackAddress) {
                        host.hostAddress
                    } else {
                        null
                    }
                    if (!ip.isNullOrEmpty()) {
                        emitResolved(resolved, ip)
                    }
                    processNextLegacyResolve(manager)
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "resolveService exception: ${e.message}")
            processNextLegacyResolve(manager)
        }
    }

    private fun pickIpv4Address(addresses: List<InetAddress>): String? {
        for (addr in addresses) {
            if (addr is Inet4Address && !addr.isLoopbackAddress) {
                val host = addr.hostAddress
                if (!host.isNullOrEmpty() && !host.startsWith("169.254.")) {
                    return host
                }
            }
        }
        return null
    }

    private fun emitResolved(info: NsdServiceInfo, ip: String) {
        val attrs = info.attributes ?: emptyMap()
        fun attr(key: String): String? {
            val raw = attrs[key] ?: return null
            return String(raw, StandardCharsets.UTF_8)
        }

        val svcName = info.serviceName ?: ""
        val fallbackId = svcName.removePrefix(SERVICE_PREFIX)
        val id = attr("id")?.takeIf { it.isNotEmpty() } ?: fallbackId
        if (id.isEmpty() || id == localServiceId) return

        val name = attr("name")?.takeIf { it.isNotEmpty() } ?: "SendSnap Device"
        val deviceType = attr("deviceType")?.takeIf { it.isNotEmpty() } ?: "unknown"
        val port = if (info.port > 0) info.port else 53318

        val payload = mapOf<String, Any>(
            "id" to id,
            "name" to name,
            "ip" to ip,
            "port" to port,
            "deviceType" to deviceType
        )
        mainHandler.post {
            onFoundCallback?.invoke(payload)
        }
    }

    fun stopDiscovery() {
        val manager = nsdManager
        val listener = discoveryListener
        discoveryListener = null
        synchronized(resolveQueue) {
            resolveQueue.clear()
            isResolvingLegacy = false
        }
        if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callbacks = activeInfoCallbacks.toList()
            activeInfoCallbacks.clear()
            for (cb in callbacks) {
                try {
                    @Suppress("UNCHECKED_CAST")
                    manager.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback)
                } catch (_: Exception) {}
            }
        }
        if (manager != null && listener != null) {
            try {
                manager.stopServiceDiscovery(listener)
            } catch (e: Exception) {
                Log.w(TAG, "stopServiceDiscovery note: ${e.message}")
            }
        }
    }

    fun dispose() {
        stopDiscovery()
        unregisterService()
        onFoundCallback = null
        onLostCallback = null
    }
}
