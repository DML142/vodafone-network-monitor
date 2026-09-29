package ua.networkdiagnostics.vodafone_network_monitor

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.UUID

data class MonitorSession(
    val id: String,
    val startedAtUtc: Long,
    val endedAtUtc: Long?,
)

class MonitorDatabase(context: Context) :
    SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                started_at_utc INTEGER NOT NULL,
                ended_at_utc INTEGER,
                stop_reason TEXT
            )""".trimIndent(),
        )
        db.execSQL(
            """CREATE TABLE measurements (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                observed_at_utc INTEGER NOT NULL,
                event_type TEXT NOT NULL,
                event_reason TEXT,
                route_available INTEGER,
                transport TEXT,
                has_internet_capability INTEGER,
                os_validated INTEGER,
                probe_success INTEGER,
                dns_ms INTEGER,
                latency_ms INTEGER,
                http_status INTEGER,
                failure_stage TEXT,
                failure_reason TEXT,
                radio_technology TEXT,
                radio_registered INTEGER,
                signal_dbm INTEGER,
                rsrp_dbm INTEGER,
                rsrq_db INTEGER,
                rssnr_db INTEGER,
                channel INTEGER,
                radio_age_ms INTEGER,
                download_mbps REAL,
                upload_mbps REAL
            )""".trimIndent(),
        )
        db.execSQL("CREATE TABLE preferences (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        db.execSQL(
            "CREATE INDEX measurements_by_session_time " +
                "ON measurements(session_id, observed_at_utc)",
        )
        db.execSQL("CREATE INDEX sessions_by_start ON sessions(started_at_utc)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE measurements ADD COLUMN download_mbps REAL")
            db.execSQL("ALTER TABLE measurements ADD COLUMN upload_mbps REAL")
            db.execSQL("CREATE TABLE preferences (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        }
    }

    fun createSession(nowUtc: Long = System.currentTimeMillis()): MonitorSession {
        val session = MonitorSession(UUID.randomUUID().toString(), nowUtc, null)
        writableDatabase.insertOrThrow(
            "sessions",
            null,
            ContentValues().apply {
                put("id", session.id)
                put("started_at_utc", session.startedAtUtc)
                putNull("ended_at_utc")
                putNull("stop_reason")
            },
        )
        return session
    }

    fun currentSession(): MonitorSession? {
        readableDatabase.query(
            "sessions",
            arrayOf("id", "started_at_utc", "ended_at_utc"),
            "ended_at_utc IS NULL",
            null,
            null,
            null,
            "started_at_utc DESC",
            "1",
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return MonitorSession(
                id = cursor.getString(0),
                startedAtUtc = cursor.getLong(1),
                endedAtUtc = if (cursor.isNull(2)) null else cursor.getLong(2),
            )
        }
    }

    fun finishSession(
        sessionId: String,
        reason: String,
        endedAtUtc: Long = System.currentTimeMillis(),
    ) {
        writableDatabase.update(
            "sessions",
            ContentValues().apply {
                put("ended_at_utc", endedAtUtc)
                put("stop_reason", reason)
            },
            "id = ? AND ended_at_utc IS NULL",
            arrayOf(sessionId),
        )
    }

    fun finishOpenSessions(reason: String, endedAtUtc: Long = System.currentTimeMillis()) {
        writableDatabase.update(
            "sessions",
            ContentValues().apply {
                put("ended_at_utc", endedAtUtc)
                put("stop_reason", reason)
            },
            "ended_at_utc IS NULL",
            null,
        )
    }

    fun addMeasurement(sessionId: String, values: Map<String, Any?>) {
        val columns = mapOf(
            "observedAtUtc" to "observed_at_utc",
            "eventType" to "event_type",
            "eventReason" to "event_reason",
            "routeAvailable" to "route_available",
            "transport" to "transport",
            "hasInternetCapability" to "has_internet_capability",
            "osValidated" to "os_validated",
            "success" to "probe_success",
            "dnsMillis" to "dns_ms",
            "latencyMillis" to "latency_ms",
            "httpStatus" to "http_status",
            "failureStage" to "failure_stage",
            "failureReason" to "failure_reason",
            "accessTechnology" to "radio_technology",
            "registered" to "radio_registered",
            "signalDbm" to "signal_dbm",
            "rsrpDbm" to "rsrp_dbm",
            "rsrqDb" to "rsrq_db",
            "rssnrDb" to "rssnr_db",
            "channel" to "channel",
            "ageMillis" to "radio_age_ms",
            "downloadMbps" to "download_mbps",
            "uploadMbps" to "upload_mbps",
        )
        val contentValues = ContentValues().apply {
            put("session_id", sessionId)
            columns.forEach { (source, target) ->
                putValue(target, values[source])
            }
        }
        writableDatabase.insert("measurements", null, contentValues)
    }

    fun pruneExpired(retentionDays: Int, nowUtc: Long = System.currentTimeMillis()) {
        val cutoff = nowUtc - retentionDays.coerceAtLeast(1) * MILLIS_PER_DAY
        writableDatabase.delete("sessions", "started_at_utc < ?", arrayOf(cutoff.toString()))
    }

    fun sessionSummaries(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        readableDatabase.rawQuery(
            """SELECT s.id, s.started_at_utc, s.ended_at_utc, s.stop_reason,
                COUNT(m.id) AS sample_count,
                SUM(CASE WHEN m.event_type = 'probe' AND m.probe_success = 0 THEN 1 ELSE 0 END) AS failed_probes
                FROM sessions s LEFT JOIN measurements m ON m.session_id = s.id
                GROUP BY s.id ORDER BY s.started_at_utc DESC""".trimIndent(),
            null,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                result.add(
                    mapOf(
                        "id" to cursor.getString(0),
                        "startedAtUtc" to cursor.getLong(1),
                        "endedAtUtc" to if (cursor.isNull(2)) null else cursor.getLong(2),
                        "stopReason" to if (cursor.isNull(3)) null else cursor.getString(3),
                        "sampleCount" to cursor.getInt(4),
                        "failedProbes" to if (cursor.isNull(5)) 0 else cursor.getInt(5),
                    ),
                )
            }
        }
        return result
    }

    fun measurements(sessionId: String, sinceUtc: Long? = null): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        val where = if (sinceUtc == null) "session_id = ?" else "session_id = ? AND observed_at_utc >= ?"
        val arguments = if (sinceUtc == null) {
            arrayOf(sessionId)
        } else {
            arrayOf(sessionId, sinceUtc.toString())
        }
        readableDatabase.query(
            "measurements",
            null,
            where,
            arguments,
            null,
            null,
            "observed_at_utc ASC, id ASC",
        ).use { cursor ->
            val names = cursor.columnNames
            while (cursor.moveToNext()) {
                rows.add(names.associateWith { name ->
                    val index = cursor.getColumnIndexOrThrow(name)
                    if (cursor.isNull(index)) null else when (cursor.getType(index)) {
                        android.database.Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(index)
                        android.database.Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(index)
                        android.database.Cursor.FIELD_TYPE_STRING -> cursor.getString(index)
                        else -> null
                    }
                })
            }
        }
        return rows
    }

    fun deleteSession(sessionId: String): Int =
        writableDatabase.delete("sessions", "id = ?", arrayOf(sessionId))

    fun deleteAll(): Int = writableDatabase.delete("sessions", null, null)

    fun getPreferences(): Map<String, String> {
        val values = mutableMapOf<String, String>()
        readableDatabase.query("preferences", arrayOf("key", "value"), null, null, null, null, null)
            .use { cursor ->
                while (cursor.moveToNext()) values[cursor.getString(0)] = cursor.getString(1)
            }
        return values
    }

    fun setPreferences(values: Map<String, String>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            values.forEach { (key, value) ->
                db.insertWithOnConflict(
                    "preferences",
                    null,
                    ContentValues().apply {
                        put("key", key)
                        put("value", value)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun ContentValues.putValue(key: String, value: Any?) {
        when (value) {
            null -> putNull(key)
            is Boolean -> put(key, if (value) 1 else 0)
            is Int -> put(key, value)
            is Long -> put(key, value)
            is Double -> put(key, value)
            is Float -> put(key, value)
            is String -> put(key, value)
            else -> put(key, value.toString())
        }
    }

    private companion object {
        const val DATABASE_NAME = "network-monitor.sqlite"
        const val DATABASE_VERSION = 2
        const val MILLIS_PER_DAY = 24L * 60L * 60L * 1000L
    }
}
