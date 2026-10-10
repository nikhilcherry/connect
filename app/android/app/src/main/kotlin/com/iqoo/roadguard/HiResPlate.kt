package com.iqoo.roadguard

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** One full-resolution photo from the camera: the JPEG bytes and how to turn it upright. */
class Still(val jpeg: ByteArray, val rotation: Int)

/** Something that can take a full-resolution still (the running camera). */
interface StillSource {
    /** Blocks up to [timeoutMs] for a still; null if it could not be taken. */
    fun captureStill(timeoutMs: Long): Still?
}

/** What the full-resolution pass found for one vehicle. */
class HiResResult(
    val plateCrop: Bitmap?,
    val plateText: String,
    val plateValid: Boolean,
    /** The vehicle at full detail (longest side at most 1600 px) for the report. */
    val vehicle: Bitmap?,
)

/**
 * Number-plate capture at full resolution. At road distance a plate is a few pixels wide in the frames
 * the models watch, but the sensor can take a photo with ten times the detail. When a violation is
 * confirmed this takes one such still, cuts the vehicle out of it at full resolution, finds the plate
 * there, and reads it. If the first still misses (the vehicle has moved on), it tries once more where
 * the tracker now has the vehicle.
 */
class PlateHiRes(private val detector: () -> NativeDetector?) {
    private val exec = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    @Volatile private var lastStartMs = 0L

    /**
     * Starts a full-resolution pass in the background and calls [done] with the result (null if no still
     * could be taken). Returns false, without calling [done], if one is already running or one just ran.
     * [box] gives the vehicle's current box in upright-frame pixels, so a second try can follow it.
     */
    fun start(source: StillSource, frameW: Int, frameH: Int, box: () -> RectF, done: (HiResResult?) -> Unit): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastStartMs < 1200 || !busy.compareAndSet(false, true)) return false
        lastStartMs = now
        exec.execute {
            var result: HiResResult? = null
            try {
                result = attempts(source, frameW, frameH, box)
            } catch (t: Throwable) {
                Log.w(TAG, "hi-res plate pass failed: $t")
            } finally {
                busy.set(false)
            }
            done(result)
        }
        return true
    }

    fun close() = exec.shutdown()

    private fun attempts(source: StillSource, fw: Int, fh: Int, box: () -> RectF): HiResResult? {
        var best: HiResResult? = null
        for (attempt in 0 until 2) {
            if (attempt > 0) Thread.sleep(450)
            val still = source.captureStill(2500) ?: continue
            val r = process(still, fw, fh, RectF(box())) ?: continue
            if (best == null || (r.plateValid && !best.plateValid) || (best.plateCrop == null && r.plateCrop != null)) best = r
            if (r.plateValid) break
        }
        return best
    }

    private fun process(still: Still, fw: Int, fh: Int, box: RectF): HiResResult? {
        val decoder = BitmapRegionDecoder.newInstance(still.jpeg, 0, still.jpeg.size, false) ?: return null
        try {
            // The vehicle's place in the stored JPEG, with a generous margin because it has moved since.
            val n = StillMapper.expandNormalized(box.left, box.top, box.right, box.bottom, fw, fh, 0.5f)
            val s = StillMapper.toStored(n, still.rotation)
            val rect = Rect(
                (s.l * decoder.width).toInt().coerceIn(0, decoder.width - 2),
                (s.t * decoder.height).toInt().coerceIn(0, decoder.height - 2),
                (s.r * decoder.width).toInt().coerceIn(2, decoder.width),
                (s.b * decoder.height).toInt().coerceIn(2, decoder.height),
            )
            if (rect.width() < 64 || rect.height() < 64) return null
            val raw = decoder.decodeRegion(rect, BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }) ?: return null
            val region = if (still.rotation != 0) {
                Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, Matrix().apply { postRotate(still.rotation.toFloat()) }, true)
            } else raw
            Log.i(TAG, "hi-res region ${region.width}x${region.height} from a ${decoder.width}x${decoder.height} still")

            val vehicle = scaleDown(region, 1600)
            // Find the plate on a view of at most 960 px, then cut it from the full-resolution region.
            val k = minOf(1f, 960f / maxOf(region.width, region.height))
            val view = if (k < 1f) Bitmap.createScaledBitmap(region, maxOf(1, (region.width * k).toInt()), maxOf(1, (region.height * k).toInt()), true) else region
            val det = detector() ?: return HiResResult(null, "", false, vehicle)
            val found = det.detect(view)?.detections?.sortedByDescending { it.score }?.take(3).orEmpty()

            var best: HiResResult? = null
            for (d in found) {
                val l = d.box.left / k
                val t = d.box.top / k
                val r = d.box.right / k
                val b = d.box.bottom / k
                val padX = (r - l) * 0.15f
                val padY = (b - t) * 0.25f
                val x0 = maxOf(0, (l - padX).toInt())
                val y0 = maxOf(0, (t - padY).toInt())
                val x1 = minOf(region.width, (r + padX).toInt())
                val y1 = minOf(region.height, (b + padY).toInt())
                if (x1 - x0 < 24 || y1 - y0 < 8) continue
                var crop = Bitmap.createBitmap(region, x0, y0, x1 - x0, y1 - y0)
                if (crop.width < 240) crop = Bitmap.createScaledBitmap(crop, 240, maxOf(1, crop.height * 240 / crop.width), true)
                val ocr = PlateReader.read(crop)
                val res = HiResResult(crop, ocr?.text ?: "", ocr?.valid == true, vehicle)
                Log.i(TAG, "hi-res plate crop ${crop.width}x${crop.height} text='${res.plateText}' valid=${res.plateValid}")
                if (res.plateValid) return res
                if (best == null) best = res
            }
            return best ?: HiResResult(null, "", false, vehicle)
        } finally {
            decoder.recycle()
        }
    }

    private fun scaleDown(b: Bitmap, maxSide: Int): Bitmap {
        val k = minOf(1f, maxSide.toFloat() / maxOf(b.width, b.height))
        return if (k < 1f) Bitmap.createScaledBitmap(b, maxOf(1, (b.width * k).toInt()), maxOf(1, (b.height * k).toInt()), true) else b
    }

    companion object {
        const val TAG = "RoadGuard"
    }
}
