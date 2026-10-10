package com.iqoo.roadguard

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.File
import kotlin.concurrent.thread

/**
 * Scans a video file in place of the camera: frames are taken every 66 ms of video time (about 15 per
 * second), turned upright and run through the same pipeline as camera frames. The video loops until
 * Drive Mode stops. Used when the person picks "Scan a video instead".
 */
class VideoRunner(private val file: File) {
    @Volatile
    private var running = true

    init {
        Hub.demoActive = true
    }

    private val worker = thread(name = "video-runner") {
        val pipeline = Hub.pipeline
        while (running && pipeline != null && !pipeline.ready) Thread.sleep(200)
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(file.path)
            val durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            Log.i("RoadGuard", "video scan: ${file.name} ${durationMs / 1000}s")
            if (durationMs <= 0L || pipeline == null) return@thread
            // Decode straight to the size the models use: far faster than decoding 1080p and shrinking.
            val rot = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            var vw = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var vh = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            if (rot == 90 || rot == 270) { val x = vw; vw = vh; vh = x }
            val k = if (vw > 0 && vh > 0) minOf(1f, 1280f / maxOf(vw, vh)) else 1f
            vw = (vw * k).toInt(); vh = (vh * k).toInt()
            var windowStart = System.nanoTime()
            var frames = 0
            while (running) {
                pipeline.resetTracking()
                var t = 0L
                while (running && t < durationMs) {
                    val t0 = System.nanoTime()
                    val raw = frameAt(mmr, t * 1000, vw, vh) ?: run { t += 66; null }
                    if (raw == null) continue
                    t += 66
                    val bmp = upright(raw)
                    Hub.overlay = pipeline.process(bmp, System.currentTimeMillis())
                    Hub.lastFrame = bmp
                    frames++
                    val now = System.nanoTime()
                    if (now - windowStart >= 1_000_000_000L) {
                        Hub.fps = frames * 1e9f / (now - windowStart)
                        pipeline.governor.update(System.currentTimeMillis())
                        val st = pipeline.stats
                        Log.i(
                            "RoadGuard",
                            "video fps=%.1f t=%ds violations=%d | bikes=%d persons=%d bikeFrames=%d maxRiders=%d helmetChecks=%d helmet=%d noHelmet=%d ai[calls=%d]".format(
                                Hub.fps, t / 1000, st.violations, st.rawBikes, st.rawPersons, st.bikeFrames, st.maxRiders,
                                st.helmetChecks, st.helmetSeen, st.noHelmetSeen, pipeline.ai.calls,
                            ),
                        )
                        frames = 0
                        windowStart = now
                    }
                    val spent = (now - t0) / 1_000_000
                    if (spent < 66) Thread.sleep(66 - spent)
                }
            }
        } catch (t: Throwable) {
            Log.w("RoadGuard", "video scan failed: $t")
        } finally {
            mmr.release()
        }
    }

    private fun frameAt(mmr: MediaMetadataRetriever, us: Long, w: Int, h: Int): Bitmap? =
        if (w > 0 && h > 0 && android.os.Build.VERSION.SDK_INT >= 27) mmr.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, w, h)
        else mmr.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)

    /** At most 1920 px on the long side (a plate needs the detail), and a plain ARGB_8888 bitmap. */
    private fun upright(src: Bitmap): Bitmap {
        val k = minOf(1f, 1920f / maxOf(src.width, src.height))
        val scaled = if (k < 1f) Bitmap.createScaledBitmap(src, (src.width * k).toInt(), (src.height * k).toInt(), true) else src
        return if (scaled.config == Bitmap.Config.ARGB_8888 && scaled.isMutable) scaled else scaled.copy(Bitmap.Config.ARGB_8888, true)
    }

    fun stop() {
        running = false
        Hub.demoActive = false
        worker.join(3000)
    }
}
