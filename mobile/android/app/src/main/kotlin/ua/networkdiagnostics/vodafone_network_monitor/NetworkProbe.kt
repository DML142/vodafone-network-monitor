package ua.networkdiagnostics.vodafone_network_monitor

import java.net.InetAddress
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

object NetworkProbe {
    private const val DEFAULT_HOST = "connectivitycheck.gstatic.com"
    private const val DEFAULT_URL = "https://connectivitycheck.gstatic.com/generate_204"
    private const val TIMEOUT_MILLIS = 7_000

    fun run(host: String = DEFAULT_HOST, probeUrl: String = DEFAULT_URL): Map<String, Any?> {
        val startedAtUtc = System.currentTimeMillis()
        val startedAtNanos = System.nanoTime()
        var dnsMillis: Long? = null

        try {
            InetAddress.getAllByName(host)
            dnsMillis = elapsedMillis(startedAtNanos)
        } catch (error: Exception) {
            return result(
                startedAtUtc = startedAtUtc,
                dnsMillis = null,
                latencyMillis = null,
                httpStatus = null,
                failureStage = "dns",
                failureReason = reasonFor(error),
            )
        }

        val connection = try {
            URL(probeUrl).openConnection() as HttpURLConnection
        } catch (error: Exception) {
            return result(
                startedAtUtc = startedAtUtc,
                dnsMillis = dnsMillis,
                latencyMillis = null,
                httpStatus = null,
                failureStage = "https",
                failureReason = reasonFor(error),
            )
        }

        return try {
            connection.connectTimeout = TIMEOUT_MILLIS
            connection.readTimeout = TIMEOUT_MILLIS
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Cache-Control", "no-cache")
            connection.setRequestProperty("User-Agent", "VodafoneNetworkMonitor/1.0")

            val requestStartedAtNanos = System.nanoTime()
            val statusCode = connection.responseCode
            val latencyMillis = elapsedMillis(requestStartedAtNanos)
            if (statusCode == 204) {
                result(
                    startedAtUtc = startedAtUtc,
                    dnsMillis = dnsMillis,
                    latencyMillis = latencyMillis,
                    httpStatus = statusCode,
                    failureStage = null,
                    failureReason = null,
                )
            } else {
                result(
                    startedAtUtc = startedAtUtc,
                    dnsMillis = dnsMillis,
                    latencyMillis = latencyMillis,
                    httpStatus = statusCode,
                    failureStage = "https",
                    failureReason = "unexpected_http_status",
                )
            }
        } catch (error: Exception) {
            result(
                startedAtUtc = startedAtUtc,
                dnsMillis = dnsMillis,
                latencyMillis = null,
                httpStatus = null,
                failureStage = "https",
                failureReason = reasonFor(error),
            )
        } finally {
            connection.disconnect()
        }
    }

    fun validateTarget(host: String, probeUrl: String): Boolean {
        return try {
            val uri = URL(probeUrl)
            uri.protocol == "https" && uri.host.equals(host, ignoreCase = true)
        } catch (_: Exception) {
            false
        }
    }

    private fun elapsedMillis(startedAtNanos: Long): Long =
        TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAtNanos)

    private fun reasonFor(error: Exception): String = when (error) {
        is java.net.SocketTimeoutException -> "timeout"
        is java.net.UnknownHostException -> "name_not_resolved"
        is javax.net.ssl.SSLException -> "tls_error"
        is java.io.IOException -> "connection_error"
        else -> "probe_error"
    }

    private fun result(
        startedAtUtc: Long,
        dnsMillis: Long?,
        latencyMillis: Long?,
        httpStatus: Int?,
        failureStage: String?,
        failureReason: String?,
    ): Map<String, Any?> = mapOf(
        "eventType" to "probe",
        "observedAtUtc" to startedAtUtc,
        "dnsMillis" to dnsMillis,
        "latencyMillis" to latencyMillis,
        "httpStatus" to httpStatus,
        "success" to (failureReason == null),
        "failureStage" to failureStage,
        "failureReason" to failureReason,
    )
}
