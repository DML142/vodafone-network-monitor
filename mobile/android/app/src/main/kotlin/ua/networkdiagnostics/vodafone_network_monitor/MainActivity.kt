package ua.networkdiagnostics.vodafone_network_monitor

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val probeExecutor = Executors.newSingleThreadExecutor()
    private var networkEvents: NetworkStatusStreamHandler? = null

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
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        networkEvents?.onCancel(null)
        networkEvents = null
        probeExecutor.shutdownNow()
        super.onDestroy()
    }

    private companion object {
        const val METHOD_CHANNEL = "ua.networkdiagnostics.vodafone_network_monitor/methods"
        const val EVENT_CHANNEL = "ua.networkdiagnostics.vodafone_network_monitor/events"
        const val DEFAULT_HOST = "connectivitycheck.gstatic.com"
        const val DEFAULT_URL = "https://connectivitycheck.gstatic.com/generate_204"
    }
}
