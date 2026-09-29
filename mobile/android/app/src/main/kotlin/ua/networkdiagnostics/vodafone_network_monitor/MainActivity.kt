package ua.networkdiagnostics.vodafone_network_monitor

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
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
    private val radioInfo by lazy { RadioInfoProvider(applicationContext) }
    private var networkEvents: NetworkStatusStreamHandler? = null
    private var pendingRadioPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null

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

    override fun onDestroy() {
        networkEvents?.onCancel(null)
        networkEvents = null
        probeExecutor.shutdownNow()
        radioExecutor.shutdownNow()
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
    }
}
