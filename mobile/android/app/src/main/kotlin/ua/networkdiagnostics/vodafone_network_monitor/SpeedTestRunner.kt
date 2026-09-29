package ua.networkdiagnostics.vodafone_network_monitor

import android.os.SystemClock
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Random

object SpeedTestRunner {
    const val MAX_BYTES_PER_DIRECTION = 10_000_000
    private const val DOWNLOAD_URL = "https://speed.cloudflare.com/__down?bytes=$MAX_BYTES_PER_DIRECTION"
    private const val UPLOAD_URL = "https://speed.cloudflare.com/__up"
    private const val CONNECT_TIMEOUT_MILLIS = 15_000
    private const val READ_TIMEOUT_MILLIS = 90_000
    private const val BUFFER_SIZE = 32 * 1024

    fun run(): Map<String, Any?> {
        val testedAtUtc = System.currentTimeMillis()
        val download = measureDownload()
        val upload = measureUpload()
        return mapOf(
            "eventType" to "speed_test",
            "observedAtUtc" to testedAtUtc,
            "downloadMbps" to download.first,
            "downloadError" to download.second,
            "downloadBytes" to if (download.first == null) 0 else MAX_BYTES_PER_DIRECTION,
            "uploadMbps" to upload.first,
            "uploadError" to upload.second,
            "uploadBytes" to if (upload.first == null) 0 else MAX_BYTES_PER_DIRECTION,
            "maxBytesPerDirection" to MAX_BYTES_PER_DIRECTION,
            "target" to "speed.cloudflare.com",
        )
    }

    private fun measureDownload(): Pair<Double?, String?> {
        val connection = try {
            (URL(DOWNLOAD_URL).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = CONNECT_TIMEOUT_MILLIS
                readTimeout = READ_TIMEOUT_MILLIS
                useCaches = false
                setRequestProperty("Cache-Control", "no-cache")
                setRequestProperty("Accept-Encoding", "identity")
                setRequestProperty("User-Agent", "VodafoneNetworkMonitor/1.0")
            }
        } catch (error: Exception) {
            return null to reason(error)
        }

        return try {
            val started = SystemClock.elapsedRealtimeNanos()
            val status = connection.responseCode
            if (status != HttpURLConnection.HTTP_OK) throw IOException("http_$status")
            connection.inputStream.use { input ->
                val buffer = ByteArray(BUFFER_SIZE)
                var received = 0
                while (received < MAX_BYTES_PER_DIRECTION) {
                    val count = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES_PER_DIRECTION - received))
                    if (count < 0) break
                    received += count
                }
                if (received != MAX_BYTES_PER_DIRECTION) throw IOException("incomplete_download")
                mbps(received, SystemClock.elapsedRealtimeNanos() - started) to null
            }
        } catch (error: Exception) {
            null to reason(error)
        } finally {
            connection.disconnect()
        }
    }

    private fun measureUpload(): Pair<Double?, String?> {
        val connection = try {
            (URL(UPLOAD_URL).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = CONNECT_TIMEOUT_MILLIS
                readTimeout = READ_TIMEOUT_MILLIS
                doOutput = true
                useCaches = false
                setFixedLengthStreamingMode(MAX_BYTES_PER_DIRECTION)
                setRequestProperty("Content-Type", "application/octet-stream")
                setRequestProperty("Cache-Control", "no-cache")
                setRequestProperty("User-Agent", "VodafoneNetworkMonitor/1.0")
            }
        } catch (error: Exception) {
            return null to reason(error)
        }

        return try {
            val started = SystemClock.elapsedRealtimeNanos()
            connection.outputStream.use { output ->
                val random = Random(0x564F4441464F4E45L)
                val buffer = ByteArray(BUFFER_SIZE)
                var sent = 0
                while (sent < MAX_BYTES_PER_DIRECTION) {
                    val count = minOf(buffer.size, MAX_BYTES_PER_DIRECTION - sent)
                    random.nextBytes(buffer)
                    output.write(buffer, 0, count)
                    sent += count
                }
            }
            val status = connection.responseCode
            if (status !in 200..299) throw IOException("http_$status")
            connection.inputStream.use { input ->
                val buffer = ByteArray(1024)
                while (input.read(buffer) >= 0) Unit
            }
            mbps(MAX_BYTES_PER_DIRECTION, SystemClock.elapsedRealtimeNanos() - started) to null
        } catch (error: Exception) {
            null to reason(error)
        } finally {
            connection.disconnect()
        }
    }

    private fun mbps(bytes: Int, elapsedNanos: Long): Double {
        val seconds = elapsedNanos.coerceAtLeast(1).toDouble() / 1_000_000_000.0
        return bytes * 8.0 / seconds / 1_000_000.0
    }

    private fun reason(error: Exception): String = when (error) {
        is java.net.SocketTimeoutException -> "timeout"
        is javax.net.ssl.SSLException -> "tls_error"
        is IOException -> error.message ?: "connection_error"
        else -> "connection_error"
    }
}
