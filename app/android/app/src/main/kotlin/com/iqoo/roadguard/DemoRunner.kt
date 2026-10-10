package com.iqoo.roadguard

import android.graphics.BitmapFactory
import android.util.Log
import java.io.File
import kotlin.concurrent.thread

/**
 * Test feed: plays folders of JPEG frames (one folder per clip) through the pipeline in a loop,
 * in place of the camera. Only the lab build ever passes a folder; the app never does.
 */
class DemoRunner(private val dir: File) {
    @Volatile
    private var running = true

    init {
        Hub.demoActive = true
    }

    private val worker = thread(name = "demo-runner") {
        val pipeline = Hub.pipeline
        while (running && pipeline != null && !pipeline.ready) Thread.sleep(200)
        var windowStart = System.nanoTime()
        var frames = 0
        while (running && pipeline != null) {
            val clips = dir.listFiles { f -> f.isDirectory }?.sortedBy { it.name }.orEmpty()
            if (clips.isEmpty()) {
                Thread.sleep(500)
                continue
            }
            for (clip in clips) {
                pipeline.resetTracking()
                val images = clip.listFiles { f -> f.extension == "jpg" }?.sortedBy { it.name }.orEmpty()
                for (img in images) {
                    if (!running) return@thread
                    val t0 = System.nanoTime()
                    val bmp = BitmapFactory.decodeFile(img.path) ?: continue
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
                            ("demo fps=%.1f total=%.0fms thermal=%d viol=%d (triple %d, helmet %d) " +
                                "ai[on=%s calls=%d fail=%d cost=$%.4f confirms=%d vetoes=%d]").format(
                                Hub.fps, st.totalMs, pipeline.governor.status, st.violations, st.tripleEvents, st.noHelmetEvents,
                                pipeline.ai.enabled, pipeline.ai.calls, pipeline.ai.failures, pipeline.ai.costUsd, st.aiConfirms, st.aiVetoes,
                            ),
                        )
                        frames = 0
                        windowStart = now
                    }
                    // Pace like a 15 fps camera so the tracker sees realistic gaps.
                    val spent = (now - t0) / 1_000_000
                    if (spent < 66) Thread.sleep(66 - spent)
                }
            }
        }
    }

    fun stop() {
        running = false
        Hub.demoActive = false
        worker.join(3000)
    }
}
