package ua.networkdiagnostics.vodafone_network_monitor

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.telephony.CellInfo
import android.telephony.CellInfoCdma
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoTdscdma
import android.telephony.CellInfoWcdma
import android.telephony.CellIdentityNr
import android.telephony.CellSignalStrengthNr
import android.telephony.TelephonyManager
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

class RadioInfoProvider(private val context: Context) {
    fun hasFineLocationPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun read(executor: Executor, callback: (Map<String, Any?>) -> Unit) {
        val packageManager = context.packageManager
        val hasRadioAccessFeature =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_RADIO_ACCESS)
        val hasLegacyTelephonyFeature =
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
        if (!hasRadioAccessFeature && !hasLegacyTelephonyFeature) {
            callback(unavailable("radio_feature_missing"))
            return
        }
        if (!hasFineLocationPermission()) {
            callback(unavailable("permission_required"))
            return
        }

        val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (telephony == null) {
            callback(unavailable("telephony_service_unavailable"))
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                telephony.requestCellInfoUpdate(
                    executor,
                    object : TelephonyManager.CellInfoCallback() {
                        override fun onCellInfo(cellInfo: MutableList<CellInfo>) {
                            callback(snapshot(cellInfo))
                        }

                        override fun onError(errorCode: Int, detail: Throwable?) {
                            callback(
                                unavailable(
                                    when (errorCode) {
                                        TelephonyManager.CellInfoCallback.ERROR_TIMEOUT -> "modem_timeout"
                                        TelephonyManager.CellInfoCallback.ERROR_MODEM_ERROR -> "modem_error"
                                        else -> "cell_info_error"
                                    },
                                ),
                            )
                        }
                    },
                )
                return
            } catch (_: SecurityException) {
                callback(unavailable("permission_unavailable"))
                return
            } catch (_: UnsupportedOperationException) {
                callback(unavailable("api_unsupported"))
                return
            } catch (_: RuntimeException) {
                callback(unavailable("read_error"))
                return
            }
        }

        executor.execute {
            try {
                val cellInfo = telephony.allCellInfo
                callback(snapshot(cellInfo.orEmpty()))
            } catch (_: SecurityException) {
                callback(unavailable("permission_unavailable"))
            } catch (_: RuntimeException) {
                callback(unavailable("read_error"))
            }
        }
    }

    private fun snapshot(cells: List<CellInfo>): Map<String, Any?> {
        val selected = cells.firstOrNull { it.isRegistered }
            ?: cells.firstOrNull { it is CellInfoLte || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && it is CellInfoNr) }
            ?: cells.firstOrNull()
            ?: return unavailable("os_returned_no_cell_info")

        val nowElapsed = SystemClock.elapsedRealtime()
        val ageMillis = (nowElapsed - timestampMillis(selected)).coerceAtLeast(0L)
        val accessTechnology: String
        var signalDbm: Int? = null
        var rsrpDbm: Int? = null
        var rsrqDb: Int? = null
        var rssnrDb: Int? = null
        var channel: Int? = null

        when (selected) {
            is CellInfoLte -> {
                accessTechnology = "LTE"
                signalDbm = available(selected.cellSignalStrength.dbm)
                rsrpDbm = available(selected.cellSignalStrength.rsrp)
                rsrqDb = available(selected.cellSignalStrength.rsrq)
                rssnrDb = available(selected.cellSignalStrength.rssnr)
                channel = available(selected.cellIdentity.earfcn)
            }
            is CellInfoNr -> {
                accessTechnology = "NR"
                val strength = selected.cellSignalStrength as? CellSignalStrengthNr
                val identity = selected.cellIdentity as? CellIdentityNr
                signalDbm = strength?.dbm?.let(::available)
                rsrpDbm = strength?.csiRsrp?.let(::available)
                rsrqDb = strength?.csiRsrq?.let(::available)
                rssnrDb = strength?.csiSinr?.let(::available)
                channel = identity?.nrarfcn?.let(::available)
            }
            is CellInfoWcdma -> {
                accessTechnology = "WCDMA"
                signalDbm = available(selected.cellSignalStrength.dbm)
                channel = available(selected.cellIdentity.uarfcn)
            }
            is CellInfoGsm -> {
                accessTechnology = "GSM"
                signalDbm = available(selected.cellSignalStrength.dbm)
                channel = available(selected.cellIdentity.arfcn)
            }
            is CellInfoCdma -> {
                accessTechnology = "CDMA"
                signalDbm = available(selected.cellSignalStrength.dbm)
            }
            is CellInfoTdscdma -> {
                accessTechnology = "TD-SCDMA"
                signalDbm = available(selected.cellSignalStrength.dbm)
                channel = available(selected.cellIdentity.uarfcn)
            }
            else -> {
                accessTechnology = "other"
                signalDbm = available(selected.cellSignalStrength.dbm)
            }
        }

        return mapOf(
            "available" to true,
            "status" to "available",
            "reason" to null,
            "accessTechnology" to accessTechnology,
            "registered" to selected.isRegistered,
            "signalDbm" to signalDbm,
            "rsrpDbm" to rsrpDbm,
            "rsrqDb" to rsrqDb,
            "rssnrDb" to rssnrDb,
            "channel" to channel,
            "ageMillis" to ageMillis,
            "observedAtUtc" to (System.currentTimeMillis() - ageMillis),
        )
    }

    private fun timestampMillis(cellInfo: CellInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            cellInfo.timestampMillis
        } else {
            TimeUnit.NANOSECONDS.toMillis(cellInfo.timeStamp)
        }

    private fun available(value: Int): Int? =
        if (value == CellInfo.UNAVAILABLE) null else value

    private fun unavailable(reason: String): Map<String, Any?> = mapOf(
        "available" to false,
        "status" to reason,
        "reason" to reason,
        "accessTechnology" to null,
        "registered" to null,
        "signalDbm" to null,
        "rsrpDbm" to null,
        "rsrqDb" to null,
        "rssnrDb" to null,
        "channel" to null,
        "ageMillis" to null,
        "observedAtUtc" to null,
    )
}
