package com.iqoo.roadguard

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Keeps the most recent GPS fix. Uses the platform LocationManager (no Play services needed). */
class LocationTracker(private val context: Context) {
    @Volatile var last: Location? = null
        private set
    private val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val listener = LocationListener { loc -> last = loc }

    @SuppressLint("MissingPermission")
    fun start() {
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) return
        try {
            last = manager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, listener, Looper.getMainLooper())
        } catch (_: Throwable) {
        }
    }

    fun stop() {
        try {
            manager.removeUpdates(listener)
        } catch (_: Throwable) {
        }
    }
}

/**
 * Evidence writer. Holds a rolling in-memory buffer of JPEG-compressed frames (RAM) so that every
 * violation can be saved with the seconds before it, and finishes the clip with the seconds after.
 */
class EvidenceStore(context: Context, private val location: LocationTracker) {
    private class Frame(val ts: Long, val jpeg: ByteArray)
    private class PendingClip(val dir: File, val untilMs: Long, var index: Int)

    private val root = File(context.getExternalFilesDir(null), "events").apply { mkdirs() }
    private val log = File(root, "events.jsonl")

    private val ring = ArrayDeque<Frame>()
    private val pending = ArrayList<PendingClip>()
    private val ringLock = Any()

    private val jpegExec = Executors.newSingleThreadExecutor()
    private val ioExec = Executors.newSingleThreadExecutor()
    private val counter = AtomicInteger(0)

    init {
        purgeOlderThan(7L * 24 * 3600 * 1000)
    }

    /** Evidence stays on the phone and is deleted after a week. */
    private fun purgeOlderThan(ageMs: Long) {
        val cutoff = System.currentTimeMillis() - ageMs
        root.listFiles()?.forEach { d -> if (d.isDirectory && d.lastModified() < cutoff) d.deleteRecursively() }
        if (log.exists()) {
            val keep = log.readLines().filter { ln ->
                runCatching { JSONObject(ln).optLong("timeMs") >= cutoff }.getOrDefault(false)
            }
            log.writeText(keep.joinToString("\n") + if (keep.isEmpty()) "" else "\n")
        }
    }

    fun close() {
        jpegExec.shutdown()
        ioExec.shutdown()
    }

    @Volatile var ringBytes = 0L
        private set
    @Volatile var ringFrames = 0
        private set

    var preSeconds = 4
    var postSeconds = 2
    private val maxFrames = 240
    private val maxAgeMs get() = (preSeconds + 2) * 1000L

    /** Compresses the frame on a worker thread and adds it to the RAM ring (and open clips). */
    fun addFrame(bmp: Bitmap, nowMs: Long) {
        jpegExec.execute {
            val out = ByteArrayOutputStream(120_000)
            bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
            val frame = Frame(nowMs, out.toByteArray())
            val toWrite = ArrayList<Pair<PendingClip, Int>>()
            synchronized(ringLock) {
                ring.addLast(frame)
                ringBytes += frame.jpeg.size
                while (ring.size > maxFrames || (ring.isNotEmpty() && nowMs - ring.first().ts > maxAgeMs)) {
                    ringBytes -= ring.removeFirst().jpeg.size
                }
                ringFrames = ring.size
                val it = pending.iterator()
                while (it.hasNext()) {
                    val c = it.next()
                    toWrite.add(c to c.index++)
                    if (nowMs >= c.untilMs) it.remove()
                }
            }
            for ((clip, idx) in toWrite) {
                ioExec.execute { File(clip.dir, "post_%03d.jpg".format(idx)).writeBytes(frame.jpeg) }
            }
        }
    }

    /** Saves a violation: JSON line, annotated frame, optional plate crop, and a pre/post clip. */
    fun save(
        type: String, trackId: Int, score: Float, nowMs: Long, annotated: Bitmap, plate: Bitmap?, extra: String,
        withClip: Boolean = true, plateText: String? = null, plateValid: Boolean = false,
        /** When the violation happened (a full-resolution pass can finish later than the event). */
        eventMs: Long = nowMs, vehicle: Bitmap? = null, plateHiRes: Boolean = false, locationAtEvent: Location? = null,
        /** Footage from a video clip: [occurredMs] and [locationAtEvent] are the clip's own, never the phone's now. */
        imported: Boolean = false, occurredMs: Long? = null, clipName: String? = null,
    ) {
        val id = "%s_%05d".format(type, counter.incrementAndGet())
        val dir = File(root, id).apply { mkdirs() }
        // Imported footage was not filmed here: only the clip's own place counts, and none is better than the phone's.
        val loc = if (imported) locationAtEvent else (locationAtEvent ?: location.last)
        val pre: List<Frame>
        synchronized(ringLock) {
            pre = if (withClip) ring.filter { eventMs - it.ts <= preSeconds * 1000L } else emptyList()
            if (withClip && System.currentTimeMillis() < eventMs + postSeconds * 1000L) pending.add(PendingClip(dir, eventMs + postSeconds * 1000L, 0))
        }
        // The caller hands over fresh bitmaps that it never touches again.
        val frameCopy = annotated
        val plateCopy = plate
        ioExec.execute {
            File(dir, "frame.jpg").outputStream().use { frameCopy.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            plateCopy?.let { p -> File(dir, "plate.jpg").outputStream().use { p.compress(Bitmap.CompressFormat.JPEG, 95, it) } }
            vehicle?.let { v -> File(dir, "vehicle_hr.jpg").outputStream().use { v.compress(Bitmap.CompressFormat.JPEG, 92, it) } }
            pre.forEachIndexed { i, f -> File(dir, "pre_%03d.jpg".format(i)).writeBytes(f.jpeg) }
            val json = JSONObject()
                .put("id", id).put("type", type).put("track", trackId).put("score", score.toDouble())
                .put("timeMs", eventMs).put("plateSaved", plate != null).put("note", extra)
                .put("plateHiRes", plateHiRes).put("vehicleSaved", vehicle != null)
                .put("plateText", plateText ?: "").put("plateValid", plateValid)
            if (imported) json.put("imported", true).put("clip", clipName ?: "").also { if (occurredMs != null) it.put("occurredMs", occurredMs) }
            if (loc != null) json.put("lat", loc.latitude).put("lon", loc.longitude).put("speedMps", loc.speed.toDouble())
            synchronized(log) { log.appendText(json.toString() + "\n") }
        }
    }

    fun eventsDir(): File = root
}
