package ua.networkdiagnostics.vodafone_network_monitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class RecordingService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectivityManager by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private val notificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }
    private val radioInfo by lazy { RadioInfoProvider(applicationContext) }
    private lateinit var database: MonitorDatabase
    private lateinit var worker: ScheduledExecutorService
    private var sampleTask: ScheduledFuture<*>? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var activeNetwork: Network? = null

    @Volatile
    private var sessionId: String? = null

    @Volatile
    private var networkSnapshot = NetworkSnapshot()

    @Volatile
    private var radioSnapshot: Map<String, Any?> = mapOf(
        "available" to false,
        "status" to "permission_required",
    )

    @Volatile
    private var lastRadioRequestElapsed = 0L

    private var explicitStop = false

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        database = MonitorDatabase(applicationContext)
        worker = Executors.newSingleThreadScheduledExecutor()
        createNotificationChannel()
        enterForeground()
        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopRecording("stopped_by_user")
                return START_NOT_STICKY
            }
            ACTION_SETTINGS_CHANGED -> {
                if (sessionId != null) scheduleSamples()
                return START_STICKY
            }
            ACTION_START -> startNewRecording()
            else -> resumeAfterSystemRestart()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        networkCallback?.let {
            runCatching { connectivityManager.unregisterNetworkCallback(it) }
        }
        networkCallback = null
        worker.shutdownNow()
        currentSessionId = null
        isRunning = false
        if (!explicitStop) emitRecordingState(false, sessionId)
        sessionId = null
        database.close()
        super.onDestroy()
    }

    private fun startNewRecording() {
        if (sessionId != null) {
            emitRecordingState(true, sessionId)
            return
        }
        database.pruneExpired(retentionDays())
        database.finishOpenSessions("interrupted")
        val session = database.createSession()
        sessionId = session.id
        getSharedPreferences(PREFERENCES_FILE, MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_RECORDING_ACTIVE, true)
            .apply()
        currentSessionId = session.id
        explicitStop = false
        emitRecordingState(true, session.id)
        scheduleSamples()
    }

    private fun resumeAfterSystemRestart() {
        val activeSession = database.currentSession()
        val shouldResume =
            getSharedPreferences(PREFERENCES_FILE, MODE_PRIVATE)
                .getBoolean(KEY_RECORDING_ACTIVE, false) && activeSession != null
        if (!shouldResume || activeSession == null) {
            explicitStop = true
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        sessionId = activeSession.id
        currentSessionId = activeSession.id
        explicitStop = false
        emitRecordingState(true, activeSession.id)
        scheduleSamples()
    }

    private fun stopRecording(reason: String) {
        explicitStop = true
        val activeId = sessionId ?: database.currentSession()?.id
        if (activeId != null) database.finishSession(activeId, reason)
        getSharedPreferences(PREFERENCES_FILE, MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_RECORDING_ACTIVE, false)
            .apply()
        emitRecordingState(false, activeId)
        currentSessionId = null
        sessionId = null
        worker.shutdownNow()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun scheduleSamples() {
        sampleTask?.cancel(false)
        sampleTask = worker.scheduleWithFixedDelay(
            { sampleOnce() },
            0,
            probeIntervalSeconds().toLong(),
            TimeUnit.SECONDS,
        )
    }

    private fun sampleOnce() {
        val currentSessionId = sessionId ?: return
        val nowUtc = System.currentTimeMillis()
        val nowElapsed = SystemClock.elapsedRealtime()
        if (nowElapsed - lastRadioRequestElapsed >= RADIO_INTERVAL_MILLIS) {
            lastRadioRequestElapsed = nowElapsed
            radioInfo.read(worker) { values -> radioSnapshot = values }
        }

        val currentNetwork = networkSnapshot
        val settings = database.getPreferences()
        val host = settings[KEY_PROBE_HOST] ?: DEFAULT_HOST
        val probeUrl = settings[KEY_PROBE_URL] ?: DEFAULT_URL
        val probe = if (currentNetwork.routeAvailable) {
            NetworkProbe.run(host, probeUrl)
        } else {
            mapOf(
                "eventType" to "probe",
                "observedAtUtc" to nowUtc,
                "dnsMillis" to null,
                "latencyMillis" to null,
                "httpStatus" to null,
                "success" to false,
                "failureStage" to "network",
                "failureReason" to "no_route",
            )
        }
        val radio = radioSnapshot
        val measurement = mutableMapOf<String, Any?>(
            "eventType" to "probe",
            "observedAtUtc" to (probe["observedAtUtc"] ?: nowUtc),
            "routeAvailable" to currentNetwork.routeAvailable,
            "transport" to currentNetwork.transport,
            "hasInternetCapability" to currentNetwork.hasInternetCapability,
            "osValidated" to currentNetwork.osValidated,
            "success" to probe["success"],
            "dnsMillis" to probe["dnsMillis"],
            "latencyMillis" to probe["latencyMillis"],
            "httpStatus" to probe["httpStatus"],
            "failureStage" to probe["failureStage"],
            "failureReason" to probe["failureReason"],
            "accessTechnology" to radio["accessTechnology"],
            "registered" to radio["registered"],
            "signalDbm" to radio["signalDbm"],
            "rsrpDbm" to radio["rsrpDbm"],
            "rsrqDb" to radio["rsrqDb"],
            "rssnrDb" to radio["rssnrDb"],
            "channel" to radio["channel"],
            "ageMillis" to radio["ageMillis"],
        )
        if (sessionId != currentSessionId) return
        database.addMeasurement(currentSessionId, measurement)
        updateNotification(currentNetwork, probe["success"] == true)
    }

    private fun registerNetworkCallback() {
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                activeNetwork = network
                updateNetwork(
                    NetworkSnapshot(routeAvailable = true, transport = "unknown"),
                    "route_available",
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
                updateNetwork(
                    NetworkSnapshot(
                        routeAvailable = true,
                        transport = transport,
                        hasInternetCapability =
                            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                        osValidated =
                            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                    ),
                    "network_capabilities_changed",
                )
            }

            override fun onLost(network: Network) {
                if (activeNetwork != network) return
                activeNetwork = null
                updateNetwork(NetworkSnapshot(transport = "none"), "route_lost")
            }
        }
        networkCallback = callback
        runCatching { connectivityManager.registerDefaultNetworkCallback(callback, mainHandler) }
            .onFailure {
                updateNetwork(NetworkSnapshot(transport = "unknown"), "network_callback_unavailable")
            }
    }

    private fun updateNetwork(updated: NetworkSnapshot, reason: String) {
        val previous = networkSnapshot
        networkSnapshot = updated
        if (previous == updated) return

        val currentSessionId = sessionId ?: return
        database.addMeasurement(
            currentSessionId,
            mapOf(
                "eventType" to "network_transition",
                "eventReason" to reason,
                "observedAtUtc" to System.currentTimeMillis(),
                "routeAvailable" to updated.routeAvailable,
                "transport" to updated.transport,
                "hasInternetCapability" to updated.hasInternetCapability,
                "osValidated" to updated.osValidated,
            ),
        )
    }

    private fun enterForeground() {
        val notification = buildNotification(networkSnapshot, isSuccessful = null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                if (canContinueLocationAccess()) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                } else {
                    0
                }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun canContinueLocationAccess(): Boolean {
        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        return radioInfo.hasFineLocationPermission() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || locationManager?.isLocationEnabled == true)
    }

    private fun probeIntervalSeconds(): Int =
        database.getPreferences()[KEY_PROBE_INTERVAL_SECONDS]?.toIntOrNull()
            ?.coerceIn(MIN_PROBE_INTERVAL_SECONDS, MAX_PROBE_INTERVAL_SECONDS)
            ?: DEFAULT_PROBE_INTERVAL_SECONDS

    private fun retentionDays(): Int =
        database.getPreferences()[KEY_RETENTION_DAYS]?.toIntOrNull()
            ?.coerceIn(1, MAX_RETENTION_DAYS)
            ?: DEFAULT_RETENTION_DAYS

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        notificationManager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                "Запись диагностики сети",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Показывает активную пользовательскую запись сети"
                setShowBadge(false)
            },
        )
    }

    private fun updateNotification(snapshot: NetworkSnapshot, isSuccessful: Boolean?) {
        notificationManager.notify(NOTIFICATION_ID, buildNotification(snapshot, isSuccessful))
    }

    private fun buildNotification(
        snapshot: NetworkSnapshot,
        isSuccessful: Boolean?,
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                NOTIFICATION_ID,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val stopIntent = PendingIntent.getService(
            this,
            NOTIFICATION_ID + 1,
            Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val networkLabel = when (snapshot.transport) {
            "cellular" -> "мобильная сеть"
            "wifi" -> "Wi-Fi"
            "ethernet" -> "Ethernet"
            "vpn" -> "VPN"
            else -> "нет активной сети"
        }
        val probeLabel = when (isSuccessful) {
            true -> " · интернет доступен"
            false -> " · проба не прошла"
            null -> " · ждём первую пробу"
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_network)
            .setContentTitle("Запись сети активна")
            .setContentText("$networkLabel$probeLabel")
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_STATUS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(null, "Остановить", stopIntent).build(),
            )
            .build()
    }

    private fun emitRecordingState(recording: Boolean, id: String?) {
        sendBroadcast(
            Intent(ACTION_RECORDING_STATE)
                .setPackage(packageName)
                .putExtra(EXTRA_RECORDING, recording)
                .putExtra(EXTRA_SESSION_ID, id),
        )
    }

    private data class NetworkSnapshot(
        val routeAvailable: Boolean = false,
        val transport: String = "none",
        val hasInternetCapability: Boolean = false,
        val osValidated: Boolean = false,
    )

    companion object {
        const val ACTION_START = "ua.networkdiagnostics.vodafone_network_monitor.START_RECORDING"
        const val ACTION_STOP = "ua.networkdiagnostics.vodafone_network_monitor.STOP_RECORDING"
        const val ACTION_RECORDING_STATE = "ua.networkdiagnostics.vodafone_network_monitor.RECORDING_STATE"
        const val EXTRA_RECORDING = "recording"
        const val EXTRA_SESSION_ID = "session_id"
        const val PREFERENCES_FILE = "monitor_preferences"
        const val KEY_RECORDING_ACTIVE = "recording_active"
        const val ACTION_SETTINGS_CHANGED = "ua.networkdiagnostics.vodafone_network_monitor.SETTINGS_CHANGED"
        const val KEY_PROBE_INTERVAL_SECONDS = "probe_interval_seconds"
        const val KEY_RETENTION_DAYS = "retention_days"
        const val KEY_PROBE_HOST = "probe_host"
        const val KEY_PROBE_URL = "probe_url"
        const val DEFAULT_HOST = "connectivitycheck.gstatic.com"
        const val DEFAULT_URL = "https://connectivitycheck.gstatic.com/generate_204"
        const val DEFAULT_PROBE_INTERVAL_SECONDS = 30
        const val MIN_PROBE_INTERVAL_SECONDS = 15
        const val MAX_PROBE_INTERVAL_SECONDS = 300
        const val MAX_RETENTION_DAYS = 90
        private const val NOTIFICATION_CHANNEL = "network_recording"
        private const val NOTIFICATION_ID = 4721
        private const val RADIO_INTERVAL_MILLIS = 60_000L
        private const val DEFAULT_RETENTION_DAYS = 30

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var currentSessionId: String? = null
            private set
    }
}
