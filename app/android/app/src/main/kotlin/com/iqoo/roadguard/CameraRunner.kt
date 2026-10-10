package com.iqoo.roadguard

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.display.DisplayManager
import android.util.Log
import android.util.Size
import android.view.Display
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.Executors

/** Process-wide holder so the Activity and the foreground Service share one pipeline. */
object Hub {
    @Volatile private var pipelineRef: Pipeline? = null
    @Volatile var overlay: OverlayData? = null
    @Volatile var lastFrame: Bitmap? = null

    /** True only while a lab test feed (DemoRunner) stands in for the camera. */
    @Volatile var demoActive = false
    @Volatile var fps = 0f
    @Volatile var skipped = 0L

    val pipeline: Pipeline? get() = pipelineRef

    /** Counters at the moment a drive started, so the UI can show this drive only. */
    @Volatile var sessionStartMs = 0L
    @Volatile var base = IntArray(4)

    fun beginSession() {
        sessionStartMs = System.currentTimeMillis()
        val s = pipelineRef?.stats
        base = if (s == null) IntArray(4) else intArrayOf(s.potholeEvents, s.violations, s.tripleEvents, s.noHelmetEvents)
    }

    /** Release the models and GPU memory when the drive ends. */
    @Synchronized
    fun stop() {
        pipelineRef?.close()
        pipelineRef = null
        overlay = null
        lastFrame = null
        demoActive = false
        fps = 0f
    }

    @Synchronized
    fun start(context: Context) {
        if (pipelineRef != null) return
        val p = Pipeline(context.applicationContext)
        pipelineRef = p
        Thread({ p.load() }, "model-loader").start()
    }
}

/** Binds CameraX analysis (and optionally a preview) and feeds frames to the pipeline. */
class CameraRunner(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var analysisUseCase: ImageAnalysis? = null
    private var lastRotationCheckMs = 0L
    private var loggedGeometry = false

    /** How the phone is held right now: ROTATION_0 upright, ROTATION_90 / 270 on its side. */
    private fun displayRotation(): Int {
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        return dm.getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: Surface.ROTATION_0
    }
    private var lastProcessedMs = 0L
    private var windowStartNs = System.nanoTime()
    private var windowFrames = 0

    fun start(owner: LifecycleOwner, previewView: PreviewView?) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val p = future.get()
            provider = p
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                        ).build(),
                )
                .setTargetRotation(displayRotation()) // upright phone => rotated frames; the code below turns them upright
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
            analysis.setAnalyzer(executor) { proxy -> analyze(proxy) }
            analysisUseCase = analysis
            p.unbindAll()
            if (previewView != null) {
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } else {
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, analysis)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun stop() {
        provider?.unbindAll()
    }

    private fun analyze(proxy: ImageProxy) {
        try {
            val pipeline = Hub.pipeline ?: return
            if (!pipeline.ready) return
            val now = System.currentTimeMillis()
            pipeline.governor.update(now)
            if (pipeline.governor.paused || now - lastProcessedMs < pipeline.governor.minIntervalMs) {
                Hub.skipped++
                return
            }
            lastProcessedMs = now

            // Follow the phone if it is turned (portrait <-> landscape) while driving.
            if (now - lastRotationCheckMs > 1000) {
                lastRotationCheckMs = now
                analysisUseCase?.targetRotation = displayRotation()
            }
            var bmp = proxy.toBitmap()
            val rotation = proxy.imageInfo.rotationDegrees
            if (rotation != 0) {
                val m = Matrix().apply { postRotate(rotation.toFloat()) }
                bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            }
            if (!loggedGeometry) {
                loggedGeometry = true
                Log.i("RoadGuard", "camera geometry: rotationDegrees=$rotation display=${displayRotation()} upright frame=${bmp.width}x${bmp.height}")
            }
            Hub.overlay = pipeline.process(bmp, now)
            Hub.lastFrame = bmp

            windowFrames++
            val elapsed = (System.nanoTime() - windowStartNs) / 1e9f
            if (elapsed >= 1f) {
                Hub.fps = windowFrames / elapsed
                android.util.Log.i(
                    "RoadGuard", "run fps=%.1f processed=%d violations=%d skipped=%d".format(
                        Hub.fps, pipeline.stats.processed, pipeline.stats.violations, Hub.skipped,
                    ),
                )
                windowFrames = 0
                windowStartNs = System.nanoTime()
            }
        } finally {
            proxy.close()
        }
    }
}
