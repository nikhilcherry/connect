package com.iqoo.roadguard

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.Log
import java.util.concurrent.Executors

data class Flag(val box: RectF, val label: String, val severe: Boolean)

data class OverlayData(
    val frameW: Int,
    val frameH: Int,
    val potholes: List<Detection>,
    val vehicles: List<Detection>,
    val flags: List<Flag>,
)

class PipelineStats {
    @Volatile var potholeMs = 0f
    @Volatile var cocoMs = 0f
    @Volatile var helmetMs = 0f
    @Volatile var plateMs = 0f
    @Volatile var totalMs = 0f
    @Volatile var potholeEvents = 0
    @Volatile var violations = 0
    @Volatile var tripleEvents = 0
    @Volatile var noHelmetEvents = 0
    @Volatile var lastEvent = "-"
    @Volatile var processed = 0L
    // Diagnostics for validating the rules on real footage.
    @Volatile var bikeFrames = 0L
    @Volatile var maxRiders = 0
    @Volatile var helmetChecks = 0L
    @Volatile var helmetSeen = 0L
    @Volatile var noHelmetSeen = 0L
}

/**
 * The full on-device pipeline. Per frame:
 *  - GPU (Adreno, Vulkan): pothole detector
 *  - COCO detector for riders, bikes and vehicles (GPU; the CPU build takes ~97 ms vs ~15 ms)
 *  - then tracking, rider counting, helmet check (GPU) and plate capture (GPU) on the bike crops
 */
class Pipeline(private val ctx: Context) {
    val governor = ThermalGovernor(ctx)
    val location = LocationTracker(ctx)
    val evidence = EvidenceStore(ctx, location)
    val stats = PipelineStats()

    @Volatile var ready = false
        private set
    @Volatile private var closed = false
    @Volatile var loadInfo = "loading models..."
        private set

    private lateinit var pothole: NativeDetector
    private lateinit var coco: NativeDetector
    private lateinit var helmet: NativeDetector
    private lateinit var plate: NativeDetector

    private val gpuExec = Executors.newSingleThreadExecutor()
    private val cpuExec = Executors.newSingleThreadExecutor()
    private var tracker = IouTracker()

    /** Forget all tracks (used between unrelated clips). */
    fun resetTracking() {
        tracker = IouTracker()
    }

    private var potholeStreak = 0
    private var lastPotholeLogMs = 0L
    private var lastPotholeLat = Double.NaN
    private var lastPotholeLon = Double.NaN

    fun load() {
        val t = System.nanoTime()
        pothole = NativeDetector(ctx, "roadguard/pothole.param", "roadguard/pothole.bin", 512, 1, useGpu = true, threads = 2, confThreshold = 0.40f)
        coco = NativeDetector(
            ctx, "roadguard/coco.param", "roadguard/coco.bin", 640, 80, useGpu = true, threads = 2, confThreshold = 0.35f,
            allowedClasses = intArrayOf(PERSON, BICYCLE, CAR, MOTORCYCLE, BUS, TRUCK),
        )
        // 4-class model (0 bike, 1 helmet, 2 no-helmet, 3 plate); only helmet / no-helmet are used here.
        helmet = NativeDetector(
            ctx, "roadguard/helmet.param", "roadguard/helmet.bin", 480, 4, useGpu = true, threads = 2,
            confThreshold = 0.45f, allowedClasses = intArrayOf(HELMET_YES, HELMET_NO),
        )
        plate = NativeDetector(ctx, "roadguard/plate.param", "roadguard/plate.bin", 320, 1, useGpu = true, threads = 2, confThreshold = 0.40f)
        if (closed) {
            pothole.close(); coco.close(); helmet.close(); plate.close()
            return
        }
        location.start()
        val ok = pothole.ok && coco.ok && helmet.ok && plate.ok
        loadInfo = "pothole[${pothole.info}] coco[${coco.info}] helmet[${helmet.info}] plate[${plate.info}] " +
            "%.1fs".format((System.nanoTime() - t) / 1e9)
        Log.i(TAG, "models loaded ok=$ok $loadInfo")
        ready = ok
        if (!ok) loadInfo = "MODEL LOAD FAILED: $loadInfo"
    }

    fun close() {
        closed = true
        ready = false
        location.stop()
        gpuExec.shutdown()
        cpuExec.shutdown()
        evidence.close()
        if (::pothole.isInitialized) { pothole.close(); coco.close(); helmet.close(); plate.close() }
    }

    fun process(frame: Bitmap, nowMs: Long): OverlayData {
        val t0 = System.nanoTime()
        evidence.addFrame(frame, nowMs)
        val level = governor.level

        // A portrait frame squeezed into the models' square input keeps only half the pixels. The
        // road is in the middle of the frame (sky above, bonnet below), so look at a square window
        // there instead, then move the boxes back into full-frame coordinates.
        val tall = frame.height > frame.width * 5 / 4
        val y0 = if (tall) minOf(frame.height - frame.width, (frame.height * 0.28f).toInt()) else 0
        val view = if (tall) Bitmap.createBitmap(frame, 0, y0, frame.width, frame.width) else frame
        val fPot = gpuExec.submit<FrameResult?> { pothole.detect(view) }
        val fCoco = if (level < 2) cpuExec.submit<FrameResult?> { coco.detect(view) } else null
        val potRes = fPot.get()
        val cocoRes = fCoco?.get()
        stats.potholeMs = potRes?.inferMs ?: 0f
        stats.cocoMs = cocoRes?.inferMs ?: 0f
        if (y0 != 0) {
            potRes?.detections?.forEach { it.box.offset(0f, y0.toFloat()) }
            cocoRes?.detections?.forEach { it.box.offset(0f, y0.toFloat()) }
        }

        // Only plausible potholes are drawn or counted.
        val potholes = potRes?.detections.orEmpty().filter { plausiblePothole(it, frame) }
        handlePotholes(frame, potholes, nowMs)

        val vehicles = cocoRes?.detections.orEmpty()
        val flags = if (cocoRes != null) handleRiders(frame, vehicles, nowMs, level) else emptyList()

        stats.processed++
        stats.totalMs = (System.nanoTime() - t0) / 1e6f
        return OverlayData(frame.width, frame.height, potholes, vehicles, flags)
    }

    // ---- potholes -------------------------------------------------------------------------

    /**
     * A pothole is a modest patch on the road surface: never a big part of the picture, never in
     * the sky half, never a sliver. This removes whole-scene boxes and overlay text.
     */
    private fun plausiblePothole(d: Detection, frame: Bitmap): Boolean {
        val fw = frame.width.toFloat()
        val fh = frame.height.toFloat()
        val b = d.box
        val areaRatio = b.width() * b.height() / (fw * fh)
        val aspect = b.width() / maxOf(1f, b.height())
        return areaRatio in 0.0004f..0.20f && b.centerY() >= 0.40f * fh && aspect in 0.4f..6f
    }

    private fun handlePotholes(frame: Bitmap, dets: List<Detection>, nowMs: Long) {
        val best = dets.filter { it.score >= 0.55f }.maxByOrNull { it.score }
        potholeStreak = if (best != null) potholeStreak + 1 else 0
        if (best == null || potholeStreak < 4 || nowMs - lastPotholeLogMs < 5000) return

        val loc = location.last
        if (loc != null && !lastPotholeLat.isNaN()) {
            val d = FloatArray(1)
            android.location.Location.distanceBetween(lastPotholeLat, lastPotholeLon, loc.latitude, loc.longitude, d)
            if (d[0] < 6f) return
        }
        lastPotholeLogMs = nowMs
        loc?.let { lastPotholeLat = it.latitude; lastPotholeLon = it.longitude }
        val annotated = annotate(frame, listOf(Triple(best.box, "pothole %.2f".format(best.score), Color.RED)))
        evidence.save("pothole", 0, best.score, nowMs, annotated, null, "", withClip = false)
        stats.potholeEvents++
        stats.lastEvent = "pothole %.2f".format(best.score)
    }

    // ---- riders: triple riding + helmet ---------------------------------------------------

    private fun handleRiders(frame: Bitmap, dets: List<Detection>, nowMs: Long, level: Int): List<Flag> {
        val persons = dets.filter { it.cls == PERSON }
        val fArea = frame.width.toFloat() * frame.height
        // Ignore the filmer's own handlebars / mirrors: a motorcycle box that fills the frame.
        val bikes = dets.filter {
            it.cls == MOTORCYCLE && it.box.width() * it.box.height() < 0.35f * fArea &&
                it.box.width() < 0.6f * frame.width
        }
        val tracks = tracker.update(bikes.map { it.box })
        val flags = ArrayList<Flag>()
        var helmetMs = 0f

        for ((i, bike) in bikes.withIndex()) {
            val tr = tracks[i]
            val riders = persons.filter { isRider(it.box, bike.box) }
            tr.riderCount = riders.size
            stats.bikeFrames++
            if (riders.size > stats.maxRiders) stats.maxRiders = riders.size

            tr.tripleHits = if (riders.size >= 3) minOf(tr.tripleHits + 1, 10) else maxOf(tr.tripleHits - 1, 0)

            val seatedRiders = persons.filter { isRider(it.box, bike.box, seated = true) }
            if (level == 0 && seatedRiders.isNotEmpty() && !tr.firedNoHelmet &&
                tr.observations - tr.lastHelmetCheck >= 2 && bike.box.width() >= 90f &&
                bike.box.bottom < 0.97f * frame.height // a bike cut off by the frame edge is too uncertain
            ) {
                tr.lastHelmetCheck = tr.observations
                val union = RectF(seatedRiders[0].box)
                seatedRiders.forEach { union.union(it.box) }
                val c = crop(frame, union, 0.08f)
                if (c != null) {
                    val r = helmet.detect(c.bmp)
                    helmetMs += r?.inferMs ?: 0f
                    val no = r?.detections?.count { it.cls == HELMET_NO && it.score >= 0.5f } ?: 0
                    val yes = r?.detections?.count { it.cls == HELMET_YES && it.score >= 0.5f } ?: 0
                    stats.helmetChecks++
                    stats.noHelmetSeen += no
                    stats.helmetSeen += yes
                    if (no > 0) tr.noHelmetHits = minOf(tr.noHelmetHits + 1, 10)
                    else if (yes > 0) tr.noHelmetHits = maxOf(tr.noHelmetHits - 1, 0)
                }
            }

            if (!tr.firedTriple && tr.tripleHits >= 4) {
                tr.firedTriple = true
                if (fire("triple_riding", tr, bike, frame, nowMs, "riders=${riders.size}")) stats.tripleEvents++
            }
            if (!tr.firedNoHelmet && tr.noHelmetHits >= 3) {
                tr.firedNoHelmet = true
                if (fire("no_helmet", tr, bike, frame, nowMs, "riders=${seatedRiders.size}")) stats.noHelmetEvents++
            }

            if (tr.firedTriple) addFlag(flags, Flag(bike.box, "TRIPLE RIDING", true))
            else if (riders.size >= 3) addFlag(flags, Flag(bike.box, "${riders.size} riders", false))
            if (tr.firedNoHelmet) addFlag(flags, Flag(bike.box, "NO HELMET", true))
        }
        if (helmetMs > 0f) stats.helmetMs = helmetMs
        return flags
    }

    private class Recent(val type: String, val box: RectF, val ts: Long)
    private val recent = ArrayList<Recent>()

    /** The same bike can be re-tracked under a new id; do not report it twice within 6 s. */
    private fun isDuplicate(type: String, box: RectF, nowMs: Long): Boolean {
        recent.removeAll { nowMs - it.ts > 6000 }
        if (recent.any { it.type == type && IouTracker.iou(it.box, box) > 0.25f }) return true
        recent.add(Recent(type, RectF(box), nowMs))
        return false
    }

    /** Two tracks on the same bike must not stack two identical labels. */
    private fun addFlag(flags: MutableList<Flag>, f: Flag) {
        if (flags.none { it.label == f.label && IouTracker.iou(it.box, f.box) > 0.5f }) flags.add(f)
    }

    private fun fire(type: String, tr: Track, bike: Detection, frame: Bitmap, nowMs: Long, note: String): Boolean {
        if (isDuplicate(type, bike.box, nowMs)) return false
        var plateCrop: Bitmap? = null
        var plateBoxInFrame: RectF? = null
        val level = governor.level
        if (level < 2) {
            val c = crop(frame, bike.box, 0.10f)
            if (c != null) {
                val r = plate.detect(c.bmp)
                stats.plateMs = r?.inferMs ?: 0f
                val best = r?.detections?.maxByOrNull { it.score }
                if (best != null) {
                    val pb = RectF(best.box)
                    pb.offset(c.x.toFloat(), c.y.toFloat())
                    plateBoxInFrame = pb
                    plateCrop = crop(frame, pb, 0.15f, minSize = 8)?.bmp?.let { pc ->
                        // Upscale tiny plates so they are legible as evidence and usable for OCR.
                        if (pc.width < 160) {
                            val k = 160f / pc.width
                            Bitmap.createScaledBitmap(pc, 160, maxOf(1, (pc.height * k).toInt()), true)
                        } else pc
                    }
                }
            }
        }
        val plate = plateCrop?.let { PlateReader.read(it) }
        val label = if (type == "triple_riding") "TRIPLE RIDING" else "NO HELMET"
        val marks = ArrayList<Triple<RectF, String, Int>>()
        marks.add(Triple(bike.box, label, Color.rgb(255, 120, 0)))
        plateBoxInFrame?.let { marks.add(Triple(it, "plate", Color.GREEN)) }
        evidence.save(
            type, tr.id, bike.score, nowMs, annotate(frame, marks), plateCrop, note, withClip = true,
            plateText = plate?.text, plateValid = plate?.valid ?: false,
        )
        stats.violations++
        stats.lastEvent = "$label #${tr.id}" + when {
            plate != null && plate.text.isNotEmpty() -> " " + plate.text
            plateCrop != null -> " +plate"
            else -> ""
        }
        Log.i(TAG, "VIOLATION $type track=${tr.id} plate=${plate?.text} valid=${plate?.valid}")
        return true
    }

    // ---- helpers --------------------------------------------------------------------------

    /**
     * [seated] = true is the strict test used for helmet checks: a rider's legs end at or above
     * the wheel line, while a pedestrian standing next to a parked bike has feet on the ground.
     * The loose test (seated = false) is used for counting people on the bike for triple riding.
     */
    private fun isRider(person: RectF, bike: RectF, seated: Boolean = false): Boolean {
        val ix = maxOf(0f, minOf(person.right, bike.right) - maxOf(person.left, bike.left))
        val iy = maxOf(0f, minOf(person.bottom, bike.bottom) - maxOf(person.top, bike.top))
        val pa = person.width() * person.height()
        if (pa <= 0f) return false
        val cx = person.centerX()
        return ix * iy / pa >= 0.12f &&
            cx >= bike.left - 0.2f * bike.width() && cx <= bike.right + 0.2f * bike.width() &&
            person.bottom <= bike.bottom + (if (seated) 0.0f else 0.35f) * bike.height() && person.bottom >= bike.top
    }

    private class Crop(val bmp: Bitmap, val x: Int, val y: Int)

    private fun crop(src: Bitmap, r: RectF, expand: Float, minSize: Int = 24): Crop? {
        val ex = r.width() * expand
        val ey = r.height() * expand
        val x1 = maxOf(0, (r.left - ex).toInt())
        val y1 = maxOf(0, (r.top - ey).toInt())
        val x2 = minOf(src.width, (r.right + ex).toInt())
        val y2 = minOf(src.height, (r.bottom + ey).toInt())
        if (x2 - x1 < minSize || y2 - y1 < minSize) return null
        return Crop(Bitmap.createBitmap(src, x1, y1, x2 - x1, y2 - y1), x1, y1)
    }

    private fun annotate(frame: Bitmap, marks: List<Triple<RectF, String, Int>>): Bitmap {
        val out = frame.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        val box = Paint().apply { style = Paint.Style.STROKE; strokeWidth = 6f }
        val text = Paint().apply { textSize = 40f; color = Color.WHITE; setShadowLayer(5f, 0f, 0f, Color.BLACK) }
        for ((r, label, color) in marks) {
            box.color = color
            canvas.drawRect(r, box)
            canvas.drawText(label, r.left, maxOf(40f, r.top - 10f), text)
        }
        return out
    }

    companion object {
        const val TAG = "RoadGuard"
        const val PERSON = 0
        const val BICYCLE = 1
        const val CAR = 2
        const val MOTORCYCLE = 3
        const val BUS = 5
        const val TRUCK = 7
        const val HELMET_YES = 1
        const val HELMET_NO = 2
    }
}
