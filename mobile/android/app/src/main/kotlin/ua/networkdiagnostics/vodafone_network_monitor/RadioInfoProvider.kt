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
import android.telephony.CellSignalStrengthLte
import android.telephony.CellSignalStrengthNr
import android.telephony.SignalStrength
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
                            val dataNetworkType = currentDataNetworkType(telephony)
                            val cellSnapshot = snapshot(cellInfo, dataNetworkType)
                            callback(
                                if (cellSnapshot["reason"] == "cell_info_for_data_network_missing") {
                                    signalStrengthSnapshot(telephony, dataNetworkType, cellSnapshot)
                                } else {
                                    cellSnapshot
                                },
                            )
                        }

                        override fun onError(errorCode: Int, detail: Throwable?) {
                            val errorSnapshot = unavailable(
                                when (errorCode) {
                                    TelephonyManager.CellInfoCallback.ERROR_TIMEOUT -> "modem_timeout"
                                    TelephonyManager.CellInfoCallback.ERROR_MODEM_ERROR -> "modem_error"
                                    else -> "cell_info_error"
                                },
                            )
                            callback(
                                signalStrengthSnapshot(
                                    telephony,
                                    currentDataNetworkType(telephony),
                                    errorSnapshot,
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

    private fun snapshot(
        cells: List<CellInfo>,
        dataNetworkType: Int? = null,
    ): Map<String, Any?> {
        val dataCellMatcher = dataNetworkType?.let(::cellMatcherForDataNetwork)
        val selected = if (dataCellMatcher != null) {
            cells.firstOrNull { dataCellMatcher(it) && it.isRegistered }
                ?: cells.firstOrNull(dataCellMatcher)
                ?: return unavailable(
                    "cell_info_for_data_network_missing",
                    dataNetworkTechnology(dataNetworkType),
                )
        } else {
            cells.firstOrNull { it.isRegistered && isLteOrNr(it) }
                ?: cells.firstOrNull { it.isRegistered }
                ?: cells.firstOrNull(::isLteOrNr)
                ?: cells.firstOrNull()
                ?: return unavailable("os_returned_no_cell_info")
        }

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
            "source" to "cell_info",
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

    @SuppressLint("MissingPermission")
    private fun signalStrengthSnapshot(
        telephony: TelephonyManager,
        dataNetworkType: Int?,
        fallback: Map<String, Any?>,
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || dataNetworkType == null) {
            return fallback
        }

        val noSignalFallback =
            if (fallback["reason"] == "cell_info_for_data_network_missing") {
                val reason = "cell_info_and_signal_strength_missing"
                fallback + mapOf("status" to reason, "reason" to reason)
            } else {
                fallback
            }

        return try {
            val signalStrength: SignalStrength = telephony.signalStrength ?: return noSignalFallback
            val nowElapsed = SystemClock.elapsedRealtime()
            val ageMillis = (nowElapsed - signalStrength.timestampMillis).coerceAtLeast(0L)
            val accessTechnology = dataNetworkTechnology(dataNetworkType)
            val signalDbm: Int?
            val rsrpDbm: Int?
            val rsrqDb: Int?
            val rssnrDb: Int?

            when (dataNetworkType) {
                TelephonyManager.NETWORK_TYPE_LTE -> {
                    val strength = signalStrength
                        .getCellSignalStrengths(CellSignalStrengthLte::class.java)
                        .firstOrNull() ?: return noSignalFallback
                    signalDbm = available(strength.dbm)
                    rsrpDbm = available(strength.rsrp)
                    rsrqDb = available(strength.rsrq)
                    rssnrDb = available(strength.rssnr)
                }
                TelephonyManager.NETWORK_TYPE_NR -> {
                    val strength = signalStrength
                        .getCellSignalStrengths(CellSignalStrengthNr::class.java)
                        .firstOrNull() ?: return noSignalFallback
                    signalDbm = available(strength.dbm)
                    rsrpDbm = available(strength.csiRsrp)
                    rsrqDb = available(strength.csiRsrq)
                    rssnrDb = available(strength.csiSinr)
                }
                else -> return fallback
            }

            mapOf(
                "available" to true,
                "status" to "available",
                "reason" to "cell_info_missing_signal_strength_used",
                "source" to "signal_strength",
                "accessTechnology" to accessTechnology,
                "registered" to null,
                "signalDbm" to signalDbm,
                "rsrpDbm" to rsrpDbm,
                "rsrqDb" to rsrqDb,
                "rssnrDb" to rssnrDb,
                "channel" to null,
                "ageMillis" to ageMillis,
                "observedAtUtc" to (System.currentTimeMillis() - ageMillis),
            )
        } catch (_: SecurityException) {
            noSignalFallback
        } catch (_: UnsupportedOperationException) {
            noSignalFallback
        } catch (_: RuntimeException) {
            noSignalFallback
        }
    }

    @SuppressLint("MissingPermission")
    private fun currentDataNetworkType(telephony: TelephonyManager): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return try {
            telephony.dataNetworkType.takeIf { it != TelephonyManager.NETWORK_TYPE_UNKNOWN }
        } catch (_: SecurityException) {
            null
        } catch (_: UnsupportedOperationException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun cellMatcherForDataNetwork(networkType: Int): ((CellInfo) -> Boolean)? = when (networkType) {
        TelephonyManager.NETWORK_TYPE_GSM,
        TelephonyManager.NETWORK_TYPE_GPRS,
        TelephonyManager.NETWORK_TYPE_EDGE,
        -> { cell -> cell is CellInfoGsm }
        TelephonyManager.NETWORK_TYPE_LTE -> { cell -> cell is CellInfoLte }
        TelephonyManager.NETWORK_TYPE_NR -> { cell -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && cell is CellInfoNr }
        TelephonyManager.NETWORK_TYPE_UMTS,
        TelephonyManager.NETWORK_TYPE_HSDPA,
        TelephonyManager.NETWORK_TYPE_HSUPA,
        TelephonyManager.NETWORK_TYPE_HSPA,
        TelephonyManager.NETWORK_TYPE_HSPAP,
        -> { cell -> cell is CellInfoWcdma }
        TelephonyManager.NETWORK_TYPE_TD_SCDMA -> { cell -> cell is CellInfoTdscdma }
        TelephonyManager.NETWORK_TYPE_CDMA,
        TelephonyManager.NETWORK_TYPE_EVDO_0,
        TelephonyManager.NETWORK_TYPE_EVDO_A,
        TelephonyManager.NETWORK_TYPE_EVDO_B,
        TelephonyManager.NETWORK_TYPE_1xRTT,
        TelephonyManager.NETWORK_TYPE_EHRPD,
        -> { cell -> cell is CellInfoCdma }
        else -> null
    }

    private fun isLteOrNr(cellInfo: CellInfo): Boolean =
        cellInfo is CellInfoLte ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && cellInfo is CellInfoNr)

    private fun dataNetworkTechnology(networkType: Int): String = when (networkType) {
        TelephonyManager.NETWORK_TYPE_LTE -> "LTE"
        TelephonyManager.NETWORK_TYPE_NR -> "NR"
        TelephonyManager.NETWORK_TYPE_GSM,
        TelephonyManager.NETWORK_TYPE_GPRS,
        TelephonyManager.NETWORK_TYPE_EDGE,
        -> "GSM"
        TelephonyManager.NETWORK_TYPE_UMTS,
        TelephonyManager.NETWORK_TYPE_HSDPA,
        TelephonyManager.NETWORK_TYPE_HSUPA,
        TelephonyManager.NETWORK_TYPE_HSPA,
        TelephonyManager.NETWORK_TYPE_HSPAP,
        -> "WCDMA"
        TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "TD-SCDMA"
        TelephonyManager.NETWORK_TYPE_CDMA,
        TelephonyManager.NETWORK_TYPE_EVDO_0,
        TelephonyManager.NETWORK_TYPE_EVDO_A,
        TelephonyManager.NETWORK_TYPE_EVDO_B,
        TelephonyManager.NETWORK_TYPE_1xRTT,
        TelephonyManager.NETWORK_TYPE_EHRPD,
        -> "CDMA"
        else -> "сотовая сеть"
    }

    private fun timestampMillis(cellInfo: CellInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            cellInfo.timestampMillis
        } else {
            TimeUnit.NANOSECONDS.toMillis(cellInfo.timeStamp)
        }

    private fun available(value: Int): Int? =
        if (value == CellInfo.UNAVAILABLE) null else value

    private fun unavailable(
        reason: String,
        accessTechnology: String? = null,
    ): Map<String, Any?> = mapOf(
        "available" to false,
        "status" to reason,
        "reason" to reason,
        "source" to null,
        "accessTechnology" to accessTechnology,
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
