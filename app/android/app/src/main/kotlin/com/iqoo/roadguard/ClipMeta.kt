package com.iqoo.roadguard

import java.util.Calendar
import java.util.TimeZone
import kotlin.math.abs

/** One GPS fix. [timeMs] is UTC milliseconds, or null when the source has no clock (a single static place). */
data class GpsPoint(val timeMs: Long?, val lat: Double, val lon: Double)

/**
 * Where and when a video clip was recorded, worked out from the clip and files beside it, never from the
 * phone that scans it. Pure functions, no Android, so they are unit-tested.
 */
object ClipMeta {
    private const val MIN_PLAUSIBLE_YEAR = 2015
    private const val TRACK_SLACK_MS = 5 * 60 * 1000L

    private fun utcMillis(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int, ms: Int, tz: TimeZone): Long? {
        if (y < MIN_PLAUSIBLE_YEAR || mo !in 1..12 || d !in 1..31 || h !in 0..23 || mi !in 0..59 || s !in 0..60) return null
        val c = Calendar.getInstance(tz)
        c.clear()
        c.set(y, mo - 1, d, h, mi, s)
        c.set(Calendar.MILLISECOND, ms)
        return c.timeInMillis
    }

    private val utc: TimeZone = TimeZone.getTimeZone("UTC")
    private val isoRe = Regex("""(\d{4})-?(\d{2})-?(\d{2})[T ](\d{2}):?(\d{2}):?(\d{2})(?:\.(\d{1,3}))?""")

    /** The container's creation date: `20231001T133850.000Z` or `2023-10-01T13:38:50Z`. UTC, as the format says. */
    fun parseMetadataDate(s: String?): Long? {
        val m = isoRe.find(s ?: return null) ?: return null
        val g = m.groupValues
        val ms = g[7].padEnd(3, '0').take(3).toInt()
        return utcMillis(g[1].toInt(), g[2].toInt(), g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt(), ms, utc)
    }

    private val nameRe = Regex("""(20\d{2})[-_]?(\d{2})[-_]?(\d{2})[-_ T]?(\d{2})[-_:]?(\d{2})[-_:]?(\d{2})""")

    /** A dashcam's own file name carries its clock in local time: `2023_1001_133850_001.MP4`, `VID_20231001_133850.mp4`. */
    fun fromFileName(name: String, tz: TimeZone = TimeZone.getDefault()): Long? {
        val m = nameRe.find(name) ?: return null
        val v = m.groupValues.drop(1).map { it.toInt() }
        return utcMillis(v[0], v[1], v[2], v[3], v[4], v[5], 0, tz)
    }

    private val isoPlaceRe = Regex("""^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)""")

    /** ISO 6709 as the container stores it: `+12.9716+077.5946/` (an altitude may follow). */
    fun parseIso6709(s: String?): GpsPoint? {
        val m = isoPlaceRe.find((s ?: return null).trim()) ?: return null
        val lat = m.groupValues[1].toDouble()
        val lon = m.groupValues[2].toDouble()
        return valid(null, lat, lon)
    }

    private fun valid(t: Long?, lat: Double, lon: Double): GpsPoint? =
        if (abs(lat) <= 90 && abs(lon) <= 180 && !(lat == 0.0 && lon == 0.0)) GpsPoint(t, lat, lon) else null

    private fun nmeaDegrees(v: String, hemi: String): Double? {
        val dot = v.indexOf('.')
        if (dot < 3) return null
        val deg = v.substring(0, dot - 2).toDoubleOrNull() ?: return null
        val min = v.substring(dot - 2).toDoubleOrNull() ?: return null
        val d = deg + min / 60.0
        return if (hemi == "S" || hemi == "W") -d else d
    }

    /** `$GPRMC` / `$GNRMC` sentences: a valid fix with its UTC date and time. Other lines are ignored. */
    fun parseNmea(text: String): List<GpsPoint> {
        val out = ArrayList<GpsPoint>()
        for (raw in text.lineSequence()) {
            val i = raw.indexOf('$')
            if (i < 0) continue
            val f = raw.substring(i).substringBefore('*').split(',')
            if (f.size < 10 || !f[0].endsWith("RMC") || f[2] != "A") continue
            val lat = nmeaDegrees(f[3], f[4]) ?: continue
            val lon = nmeaDegrees(f[5], f[6]) ?: continue
            val t = f[1]
            val dt = f[9]
            if (t.length < 6 || dt.length != 6) continue
            val ms = utcMillis(2000 + dt.substring(4, 6).toInt(), dt.substring(2, 4).toInt(), dt.substring(0, 2).toInt(),
                t.substring(0, 2).toInt(), t.substring(2, 4).toInt(), t.substring(4, 6).toInt(), 0, utc)
            valid(ms, lat, lon)?.let { out.add(it) }
        }
        return out
    }

    private val trkptRe = Regex("""<trkpt([^>]*)>(.*?)</trkpt>""", RegexOption.DOT_MATCHES_ALL)
    private val latRe = Regex("""lat\s*=\s*"([^"]+)"""")
    private val lonRe = Regex("""lon\s*=\s*"([^"]+)"""")
    private val timeRe = Regex("""<time>([^<]+)</time>""")

    /** GPX track points with their times. */
    fun parseGpx(text: String): List<GpsPoint> = trkptRe.findAll(text).mapNotNull { m ->
        val lat = latRe.find(m.groupValues[1])?.groupValues?.get(1)?.toDoubleOrNull() ?: return@mapNotNull null
        val lon = lonRe.find(m.groupValues[1])?.groupValues?.get(1)?.toDoubleOrNull() ?: return@mapNotNull null
        valid(parseMetadataDate(timeRe.find(m.groupValues[2])?.groupValues?.get(1)), lat, lon)
    }.toList()

    /** Fixes from a sidecar file of either kind. */
    fun parseTrack(text: String): List<GpsPoint> = parseGpx(text).ifEmpty { parseNmea(text) }

    /**
     * The best place for [offsetMs] into a clip that started at [startMs]. With a timed track, the fix nearest in
     * time (and only if it is within five minutes of it: a log from another trip is not this clip's place).
     * With a single untimed place, that place. Otherwise nowhere, so nothing wrong is ever reported.
     */
    fun locationAt(points: List<GpsPoint>, startMs: Long?, offsetMs: Long): GpsPoint? {
        if (points.isEmpty()) return null
        val timed = points.filter { it.timeMs != null }
        if (timed.isNotEmpty()) {
            if (startMs == null) return timed.first()
            val target = startMs + offsetMs
            val best = timed.minByOrNull { abs(it.timeMs!! - target) } ?: return null
            return if (abs(best.timeMs!! - target) <= TRACK_SLACK_MS) best else null
        }
        return points.first()
    }

    /**
     * When the clip started. A GPS log with the clip's own name runs on satellite time, which no dashcam clock
     * beats, so its first fix wins. Without one, the container date if it is believable (an unset 1970 date is
     * not), then the clock in the file name.
     */
    fun startOf(metadataDate: String?, fileName: String, points: List<GpsPoint>, tz: TimeZone = TimeZone.getDefault()): Long? =
        points.firstOrNull { it.timeMs != null }?.timeMs ?: parseMetadataDate(metadataDate) ?: fromFileName(fileName, tz)
}
