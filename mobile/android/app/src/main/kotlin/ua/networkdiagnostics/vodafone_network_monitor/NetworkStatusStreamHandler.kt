package ua.networkdiagnostics.vodafone_network_monitor

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

class NetworkStatusStreamHandler(context: Context) : EventChannel.StreamHandler {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var activeNetwork: Network? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        eventSink = events

        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                activeNetwork = network
                emit(
                    routeAvailable = true,
                    transport = "unknown",
                    hasInternetCapability = false,
                    osValidated = false,
                )
            }

            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) {
                if (activeNetwork != network) return

                val transport = when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                    else -> "other"
                }

                emit(
                    routeAvailable = true,
                    transport = transport,
                    hasInternetCapability =
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                    osValidated =
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                )
            }

            override fun onLost(network: Network) {
                if (activeNetwork != network) return
                activeNetwork = null
                emit(
                    routeAvailable = false,
                    transport = "none",
                    hasInternetCapability = false,
                    osValidated = false,
                )
            }
        }
        callback = networkCallback

        try {
            connectivityManager.registerDefaultNetworkCallback(networkCallback, mainHandler)
        } catch (error: RuntimeException) {
            callback = null
            eventSink = null
            events.error("network_monitor_unavailable", error.javaClass.simpleName, null)
        }
    }

    override fun onCancel(arguments: Any?) {
        callback?.let { networkCallback ->
            try {
                connectivityManager.unregisterNetworkCallback(networkCallback)
            } catch (_: IllegalArgumentException) {
                // The callback can already be unregistered when the engine shuts down.
            }
        }
        callback = null
        activeNetwork = null
        eventSink = null
    }

    private fun emit(
        routeAvailable: Boolean,
        transport: String,
        hasInternetCapability: Boolean,
        osValidated: Boolean,
    ) {
        val event = mapOf(
            "eventType" to "network",
            "routeAvailable" to routeAvailable,
            "transport" to transport,
            "hasInternetCapability" to hasInternetCapability,
            "osValidated" to osValidated,
            "observedAtUtc" to System.currentTimeMillis(),
        )
        mainHandler.post { eventSink?.success(event) }
    }
}
