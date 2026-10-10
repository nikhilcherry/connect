package com.iqoo.roadguard

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import kotlin.concurrent.thread

/** Which clip is being scanned, for the progress line in the app. */
class VideoProgress(val name: String, val index: Int, val count: Int)

/**
 * Scans video clips in place of the camera, one after another, each once. Frames are taken about every 66 ms of
 * video time, turned upright and run through the same pipeline as camera frames. Every event is stamped with
 * the clip's own recorded time and place (see [ClipReader]); when a clip has none, the event has none, so it
 * cannot be reported with a wrong one. When the last clip ends, [Hub.videoDone] is set.
 */
class VideoRunner(private val context: Context, private val sources: List<ClipSource>) {
    @Volatile
    private var running = true

    init {
        Hub.demoActive = true
        Hub.videoDone = false
    }

    private val worker = thread(name = "video-runner") {
        val pipeline = Hub.pipeline
        while (running && pipeline != null && !pipeline.ready) Thread.sleep(200)
        if (pipeline == null) return@thread
        var windowStart = System.nanoTime()
        var frames = 0
        for ((i, src) in sources.withIndex()) {
            if (!running) break
            val mmr = MediaMetadataRetriever()
            try {
                ClipReader.setDataSource(context, mmr, src)
                val durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                Log.i("RoadGuard", "video scan ${i + 1}/${sources.size}: ${src.name} ${durationMs / 1000}s")
                if (durationMs <= 0L) continue
                val info = ClipReader.read(context, mmr, src)
                Hub.video = VideoProgress(src.name, i + 1, sources.size)
                pipeline.clip = info
                pipeline.clipOffsetMs = 0
                pipeline.resetTracking()
                // Decode straight to the size the models use: far faster than decoding 1080p and shrinking.
                val rot = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                var vw = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                var vh = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                if (rot == 90 || rot == 270) { val x = vw; vw = vh; vh = x }
                val k = if (vw > 0 && vh > 0) minOf(1f, 1280f / maxOf(vw, vh)) else 1f
                vw = (vw * k).toInt(); vh = (vh * k).toInt()

                var t = 0L
                while (running && t < durationMs) {
                    val t0 = System.nanoTime()
                    val raw = frameAt(mmr, t * 1000, vw, vh)
                    t += 66
                    if (raw == null) continue
                    pipeline.clipOffsetMs = t
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
                            "video fps=%.1f clip=%d/%d t=%ds violations=%d | bikes=%d persons=%d bikeFrames=%d maxRiders=%d helmetChecks=%d helmet=%d noHelmet=%d ai[calls=%d]".format(
                                Hub.fps, i + 1, sources.size, t / 1000, st.violations, st.rawBikes, st.rawPersons, st.bikeFrames, st.maxRiders,
                                st.helmetChecks, st.helmetSeen, st.noHelmetSeen, pipeline.ai.calls,
                            ),
                        )
                        frames = 0
                        windowStart = now
                    }
                    val spent = (now - t0) / 1_000_000
                    if (spent < 66) Thread.sleep(66 - spent)
                }
            } catch (t: Throwable) {
                Log.w("RoadGuard", "video scan failed on ${src.name}: $t")
            } finally {
                mmr.release()
            }
        }
        // The AI answers a second or two after it is asked; let the last answers be acted on before finishing.
        if (running && pipeline.ai.enabled && pipeline.ai.calls > 0) Thread.sleep(6000)
        Log.i("RoadGuard", "video scan finished: ${sources.size} clip(s)")
        Hub.videoDone = true
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
        Hub.video = null
        worker.join(3000)
    }
}
