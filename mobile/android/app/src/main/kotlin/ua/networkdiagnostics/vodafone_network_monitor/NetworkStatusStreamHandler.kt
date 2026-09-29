package ua.networkdiagnostics.vodafone_network_monitor

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.Build
import io.flutter.plugin.common.EventChannel

class NetworkStatusStreamHandler(context: Context) : EventChannel.StreamHandler {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var recordingStateReceiver: BroadcastReceiver? = null
    private var activeNetwork: Network? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        eventSink = events
        registerRecordingStateReceiver()
        emitRecordingState(RecordingService.isRunning, RecordingService.currentSessionId)

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
        recordingStateReceiver?.let { receiver ->
            try {
                appContext.unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
                // The receiver can already be unregistered when the engine shuts down.
            }
        }
        recordingStateReceiver = null
        activeNetwork = null
        eventSink = null
    }

    fun emitRecordingState(recording: Boolean, sessionId: String?) {
        val event = mapOf(
            "eventType" to "recording",
            "recording" to recording,
            "sessionId" to sessionId,
            "observedAtUtc" to System.currentTimeMillis(),
        )
        mainHandler.post { eventSink?.success(event) }
    }

    private fun registerRecordingStateReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != RecordingService.ACTION_RECORDING_STATE) return
                emitRecordingState(
                    intent.getBooleanExtra(RecordingService.EXTRA_RECORDING, false),
                    intent.getStringExtra(RecordingService.EXTRA_SESSION_ID),
                )
            }
        }
        recordingStateReceiver = receiver
        val filter = IntentFilter(RecordingService.ACTION_RECORDING_STATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            appContext.registerReceiver(receiver, filter)
        }
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
