package ua.networkdiagnostics.vodafone_network_monitor

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val probeExecutor = Executors.newSingleThreadExecutor()
    private val radioExecutor = Executors.newSingleThreadExecutor()
    private val speedTestExecutor = Executors.newSingleThreadExecutor()
    private val database by lazy { MonitorDatabase(applicationContext) }
    private val radioInfo by lazy { RadioInfoProvider(applicationContext) }
    private var networkEvents: NetworkStatusStreamHandler? = null
    private var pendingRadioPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        networkEvents = NetworkStatusStreamHandler(applicationContext)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(networkEvents)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "runProbe" -> {
                        val host = call.argument<String>("host") ?: DEFAULT_HOST
                        val probeUrl = call.argument<String>("url") ?: DEFAULT_URL
                        if (!NetworkProbe.validateTarget(host, probeUrl)) {
                            result.error("invalid_probe_target", "Use an HTTPS URL on the configured host.", null)
                            return@setMethodCallHandler
                        }

                        probeExecutor.execute {
                            val probeResult = NetworkProbe.run(host, probeUrl)
                            mainHandler.post { result.success(probeResult) }
                        }
                    }
                    "hasRadioPermission" -> result.success(radioInfo.hasFineLocationPermission())
                    "requestRadioPermission" -> {
                        if (radioInfo.hasFineLocationPermission()) {
                            result.success(true)
                        } else if (pendingRadioPermissionResult != null) {
                            result.error("permission_request_in_progress", "A location permission request is already open.", null)
                        } else {
                            pendingRadioPermissionResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                                RADIO_PERMISSION_REQUEST,
                            )
                        }
                    }
                    "readRadioInfo" -> {
                        radioInfo.read(radioExecutor) { radioSnapshot ->
                            mainHandler.post { result.success(radioSnapshot) }
                        }
                    }
                    "openAppSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    }
                    "hasNotificationPermission" -> {
                        result.success(hasNotificationPermission())
                    }
                    "requestNotificationPermission" -> {
                        if (hasNotificationPermission()) {
                            result.success(true)
                        } else if (pendingNotificationPermissionResult != null) {
                            result.error("permission_request_in_progress", "A notification permission request is already open.", null)
                        } else {
                            pendingNotificationPermissionResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                NOTIFICATION_PERMISSION_REQUEST,
                            )
                        }
                    }
                    "startRecording" -> {
                        if (!hasNotificationPermission()) {
                            result.error("notifications_permission_required", "Allow the recording notification first.", null)
                        } else if (RecordingService.isRunning) {
                            result.success(true)
                        } else {
                            try {
                                startForegroundService(
                                    Intent(this, RecordingService::class.java)
                                        .setAction(RecordingService.ACTION_START),
                                )
                                result.success(true)
                            } catch (error: RuntimeException) {
                                result.error("recording_start_failed", error.javaClass.simpleName, null)
                            }
                        }
                    }
                    "stopRecording" -> {
                        if (RecordingService.isRunning) {
                            startService(
                                Intent(this, RecordingService::class.java)
                                    .setAction(RecordingService.ACTION_STOP),
                            )
                        }
                        result.success(null)
                    }
                    "getRecordingState" -> result.success(
                        mapOf(
                            "recording" to RecordingService.isRunning,
                            "sessionId" to RecordingService.currentSessionId,
                        ),
                    )
                    "getSessions" -> result.success(database.sessionSummaries())
                    "getMeasurements" -> {
                        val sessionId = call.argument<String>("sessionId")
                        if (sessionId.isNullOrBlank()) {
                            result.error("session_required", "A session id is required.", null)
                        } else {
                            result.success(database.measurements(sessionId))
                        }
                    }
                    "deleteSession" -> {
                        val sessionId = call.argument<String>("sessionId")
                        if (RecordingService.isRunning && sessionId == RecordingService.currentSessionId) {
                            result.error("session_is_active", "Stop recording before deleting the active session.", null)
                        } else {
                            result.success(sessionId?.let(database::deleteSession) ?: 0)
                        }
                    }
                    "deleteAllSessions" -> {
                        if (RecordingService.isRunning) {
                            result.error("recording_is_active", "Stop recording before deleting sessions.", null)
                        } else {
                            result.success(database.deleteAll())
                        }
                    }
                    "getSettings" -> result.success(readSettings())
                    "saveSettings" -> saveSettings(call.arguments as? Map<*, *>, result)
                    "runSpeedTest" -> runSpeedTest(result)
                    "exportSession" -> {
                        val content = call.argument<String>("content")
                        val filename = call.argument<String>("filename") ?: "network-session"
                        val mimeType = call.argument<String>("mimeType") ?: "text/plain"
                        if (content == null) {
                            result.error("export_content_missing", "No session data to export.", null)
                        } else if (pendingExportResult != null) {
                            result.error("export_in_progress", "An export is already open.", null)
                        } else {
                            pendingExportContent = content
                            pendingExportResult = result
                            try {
                                startActivityForResult(
                                    Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE)
                                        type = mimeType
                                        putExtra(Intent.EXTRA_TITLE, filename)
                                    },
                                    EXPORT_REQUEST,
                                )
                            } catch (error: RuntimeException) {
                                pendingExportContent = null
                                pendingExportResult = null
                                result.error("export_picker_unavailable", error.javaClass.simpleName, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated by Android, but FlutterActivity still delivers legacy permission results here.")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RADIO_PERMISSION_REQUEST) {
            val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
            pendingRadioPermissionResult?.success(granted)
            pendingRadioPermissionResult = null
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            pendingNotificationPermissionResult?.success(granted)
            pendingNotificationPermissionResult = null
        }
    }

    @Deprecated("Deprecated by Android, retained for the system file picker result.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_REQUEST) return
        val result = pendingExportResult ?: return
        val content = pendingExportContent
        pendingExportResult = null
        pendingExportContent = null
        if (resultCode != RESULT_OK || data?.data == null || content == null) {
            result.success(false)
            return
        }
        val uri: Uri = data.data!!
        probeExecutor.execute {
            try {
                contentResolver.openOutputStream(uri, "wt")!!.use { output ->
                    output.write(content.toByteArray(Charsets.UTF_8))
                }
                mainHandler.post { result.success(true) }
            } catch (error: Exception) {
                mainHandler.post { result.error("export_write_failed", error.message, null) }
            }
        }
    }

    private fun readSettings(): Map<String, Any> {
        val saved = database.getPreferences()
        return mapOf(
            "probeIntervalSeconds" to (saved[RecordingService.KEY_PROBE_INTERVAL_SECONDS]?.toIntOrNull()
                ?.coerceIn(RecordingService.MIN_PROBE_INTERVAL_SECONDS, RecordingService.MAX_PROBE_INTERVAL_SECONDS)
                ?: RecordingService.DEFAULT_PROBE_INTERVAL_SECONDS),
            "retentionDays" to (saved[RecordingService.KEY_RETENTION_DAYS]?.toIntOrNull()?.coerceIn(1, RecordingService.MAX_RETENTION_DAYS) ?: 30),
            "probeHost" to (saved[RecordingService.KEY_PROBE_HOST] ?: RecordingService.DEFAULT_HOST),
            "probeUrl" to (saved[RecordingService.KEY_PROBE_URL] ?: RecordingService.DEFAULT_URL),
            "themeMode" to (saved[KEY_THEME_MODE] ?: "dark"),
        )
    }

    private fun saveSettings(values: Map<*, *>?, result: MethodChannel.Result) {
        val interval = (values?.get("probeIntervalSeconds") as? Number)?.toInt()
        val retention = (values?.get("retentionDays") as? Number)?.toInt()
        val host = values?.get("probeHost") as? String
        val probeUrl = values?.get("probeUrl") as? String
        val theme = values?.get("themeMode") as? String
        if (interval == null || interval !in RecordingService.MIN_PROBE_INTERVAL_SECONDS..RecordingService.MAX_PROBE_INTERVAL_SECONDS ||
            retention == null || retention !in 1..RecordingService.MAX_RETENTION_DAYS ||
            host.isNullOrBlank() || !NetworkProbe.validateTarget(host, probeUrl ?: "") ||
            theme !in setOf("system", "light", "dark")
        ) {
            result.error("invalid_settings", "One or more settings are outside the supported values.", null)
            return
        }
        database.setPreferences(
            mapOf(
                RecordingService.KEY_PROBE_INTERVAL_SECONDS to interval.toString(),
                RecordingService.KEY_RETENTION_DAYS to retention.toString(),
                RecordingService.KEY_PROBE_HOST to host,
                RecordingService.KEY_PROBE_URL to probeUrl!!,
                KEY_THEME_MODE to theme!!,
            ),
        )
        database.pruneExpired(retention)
        if (RecordingService.isRunning) {
            startService(Intent(this, RecordingService::class.java).setAction(RecordingService.ACTION_SETTINGS_CHANGED))
        }
        result.success(readSettings())
    }

    private fun runSpeedTest(result: MethodChannel.Result) {
        speedTestExecutor.execute {
            val measurement = SpeedTestRunner.run()
            try {
                val activeSession = if (RecordingService.isRunning) database.currentSession() else null
                if (activeSession == null) {
                    val retention = database.getPreferences()[RecordingService.KEY_RETENTION_DAYS]
                        ?.toIntOrNull()
                        ?.coerceIn(1, RecordingService.MAX_RETENTION_DAYS)
                        ?: 30
                    database.finishOpenSessions("interrupted")
                    database.pruneExpired(retention)
                }
                val session = activeSession ?: database.createSession()
                database.addMeasurement(session.id, measurement)
                if (activeSession == null) database.finishSession(session.id, "speed_test_completed")
                mainHandler.post { result.success(measurement) }
            } catch (error: Exception) {
                mainHandler.post { result.error("speed_test_save_failed", error.message, measurement) }
            }
        }
    }

    override fun onDestroy() {
        networkEvents?.onCancel(null)
        networkEvents = null
        probeExecutor.shutdownNow()
        radioExecutor.shutdownNow()
        speedTestExecutor.shutdownNow()
        runCatching { database.close() }
        pendingExportResult?.success(false)
        pendingExportResult = null
        pendingExportContent = null
        pendingRadioPermissionResult = null
        pendingNotificationPermissionResult = null
        super.onDestroy()
    }

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private companion object {
        const val METHOD_CHANNEL = "ua.networkdiagnostics.vodafone_network_monitor/methods"
        const val EVENT_CHANNEL = "ua.networkdiagnostics.vodafone_network_monitor/events"
        const val DEFAULT_HOST = "connectivitycheck.gstatic.com"
        const val DEFAULT_URL = "https://connectivitycheck.gstatic.com/generate_204"
        const val RADIO_PERMISSION_REQUEST = 417
        const val NOTIFICATION_PERMISSION_REQUEST = 418
        const val EXPORT_REQUEST = 419
        const val KEY_THEME_MODE = "theme_mode"
    }
}
